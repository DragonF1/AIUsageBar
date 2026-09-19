import Foundation
import Observation
import os

/// Sibling of `UsageStore` for the Antigravity tab: same polling, backoff and cache shape,
/// but the token comes from Antigravity's login and the rows are the two quota pools.
@MainActor @Observable
final class AntigravityStore {
    typealias State = UsageStore.State

    private(set) var usage: AntigravityUsage?
    private(set) var lastUpdated: Date?
    private(set) var state: State = .loading

    var client = AntigravityClient()
    var auth = AntigravityAuth()
    /// Asked when the token path fails: the running IDE has a working login of its own.
    var localProbe = AntigravityLocalProbe()
    /// Told about every successful poll, for the pace lines and the notifications.
    var monitor: QuotaMonitor?

    private var timer: Timer?
    private var backoffUntil: Date?
    private var inFlight = false

    /// `log show --info --predicate 'subsystem == "io.github.dragonf1.aiusagebar"'` reads these back.
    private static let log = Logger(subsystem: "io.github.dragonf1.aiusagebar", category: "antigravity")

    /// nil disables the cache; tests pass nil so they never touch the app's real file.
    private let cacheURL: URL?

    init(cacheURL: URL? = AppPaths.supportDirectory.appendingPathComponent("antigravity.json")) {
        self.cacheURL = cacheURL
        loadCache()
    }

    // MARK: - scheduling

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: UsageStore.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(reason: "timer") }
        }
        Task { await refresh(reason: "launch") }
    }

    func refreshIfStale() {
        let age = lastUpdated.map { Date().timeIntervalSince($0) } ?? .infinity
        if age > UsageStore.popoverRefetchAge { Task { await refresh(reason: "popover") } }
    }

    func refresh(reason: String) async {
        if inFlight {
            Self.log.info("refresh skipped (\(reason, privacy: .public)): in flight")
            return
        }
        if let until = backoffUntil, until > Date() {
            Self.log.info("refresh skipped (\(reason, privacy: .public)): backoff until \(UsageStore.timeFormatter.string(from: until), privacy: .public)")
            return
        }
        inFlight = true
        defer { inFlight = false }

        do {
            let token = try await auth.accessToken()
            do {
                try await apply(token: token, reason: reason)
            } catch UsageError.unauthorized {
                // Token rejected despite its expiry: refresh once and retry.
                let fresh = try await auth.accessToken(force: true)
                try await apply(token: fresh, reason: reason)
            }
        } catch UsageError.rateLimited(let retryAfter) {
            Self.log.error("fetch failed (\(reason, privacy: .public)): rate limited, retry in \(Int(retryAfter), privacy: .public)s")
            backoffUntil = Date().addingTimeInterval(retryAfter)
            state = usage == nil ? .error(UsageError.rateLimited(retryAfter: retryAfter).localizedDescription)
                                 : .stale("Rate limited, retrying at \(UsageStore.timeFormatter.string(from: backoffUntil!))")
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // No token file, login expired with no refresh client, token rejected twice, or the
            // backend itself unhappy: the IDE, when it is running, can still answer.
            if await applyLocal(reason: reason, after: msg) { return }
            Self.log.error("fetch failed (\(reason, privacy: .public)): \(msg, privacy: .public)")
            state = usage == nil ? .error(msg) : .stale(msg)
        }
    }

    private func apply(token: String, reason: String) async throws {
        // The account lookup names the plan and, more importantly, the backend that meters this
        // account's quota. When it fails, keep asking the backend the last good poll used; a dead
        // token still surfaces on the quota call below, which is what drives the refresh-and-retry.
        var account: AntigravityClient.Account?
        do {
            account = try await client.fetchAccount(accessToken: token)
        } catch UsageError.rateLimited(let retryAfter) {
            throw UsageError.rateLimited(retryAfter: retryAfter)
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Self.log.info("account fetch failed: \(msg, privacy: .public)")
        }
        let remembered = usage?.host.flatMap { AntigravityClient.isKnownHost($0) ? $0 : nil }
        let host = account?.host ?? remembered ?? AntigravityClient.dailyHost
        let summary = try await client.fetch(accessToken: token, host: host)
        // Default level so `log show` finds it after the fact; info and debug are memory-only.
        Self.log.notice("fetch ok (\(reason, privacy: .public)) via \(host, privacy: .public): \(summary.logLine, privacy: .public)")
        adopt(AntigravityUsage(summary: summary, tier: account?.tier ?? usage?.tier, host: host))
    }

    /// The IDE's own language server, on localhost. False when it is not running or would not
    /// answer, in which case the token path's error is the one to show: it says what to fix.
    private func applyLocal(reason: String, after tokenError: String) async -> Bool {
        let remembered = usage?.host.flatMap { AntigravityClient.isKnownHost($0) ? $0 : nil }
        do {
            let result = try await localProbe.fetch(preferring: remembered)
            // The server's backend is the one that metered these numbers, so the next poll that
            // gets a token asks the same one.
            let host = result.endpoint.flatMap { AntigravityClient.isKnownHost($0) ? $0 : nil } ?? remembered
            Self.log.notice("fetch ok (\(reason, privacy: .public)) via Antigravity pid \(result.pid, privacy: .public) port \(result.port, privacy: .public) (\(result.endpoint ?? "?", privacy: .public)), token path failed: \(tokenError, privacy: .public): \(result.summary.logLine, privacy: .public)")
            adopt(AntigravityUsage(summary: result.summary, tier: result.tier ?? usage?.tier, host: host))
            return true
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Self.log.info("local probe failed: \(msg, privacy: .public)")
            return false
        }
    }

    /// Takes a usage value as if a poll had just returned it: the rows, the tier badge, the
    /// "Updated" time and the pace tracker all follow. The screenshot renderer feeds fixtures this way.
    func adopt(_ next: AntigravityUsage, at date: Date = Date()) {
        usage = next
        lastUpdated = date
        state = .ok
        backoffUntil = nil
        saveCache()
        monitor?.observe(next.readings, now: date)
    }

    // MARK: - derived

    /// The menu bar tracks the Gemini group only, as "5h% / weekly%" like the Claude tab.
    var geminiSessionPercent: Double? { usage?.gemini?.buckets.first { $0.window == "5h" }?.percentUsed }
    var geminiWeeklyPercent: Double? { usage?.gemini?.buckets.first { $0.window == "weekly" }?.percentUsed }

    var isStale: Bool {
        if case .ok = state { return false }
        return true
    }

    // MARK: - cache

    private struct Cache: Codable {
        var usage: AntigravityUsage
        var lastUpdated: Date
    }
    private func loadCache() {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let cache = try? UsageClient.decoder.decode(Cache.self, from: data) else { return }
        usage = cache.usage
        lastUpdated = cache.lastUpdated
        state = .stale("Cached")
    }

    private func saveCache() {
        guard let cacheURL, let usage, let lastUpdated else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(Cache(usage: usage, lastUpdated: lastUpdated)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
