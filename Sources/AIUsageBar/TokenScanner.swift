import Foundation

// MARK: - Records

/// One API response from a Claude Code transcript, deduplicated on message id.
struct TokenRecord: Codable, Equatable, Sendable {
    var timestamp: Date
    /// Model id with any "[1m]" suffix stripped.
    var model: String
    var input: Int
    var output: Int
    var cacheWrite5m: Int
    var cacheWrite1h: Int
    var cacheRead: Int
    /// The session the response belongs to; subagent transcripts carry their parent's id.
    var sessionId: String? = nil

    var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }
}

/// What a transcript says about its session beyond the token records: the title Claude Code
/// gives it, the launcher colour, where it runs, and when it was first and last seen answering.
struct SessionMeta: Codable, Equatable, Sendable, Identifiable {
    var sessionId: String
    var title: String?
    var lastPrompt: String?
    var color: String?
    var cwd: String?
    var gitBranch: String?
    var slug: String?
    var firstSeen: Date
    var lastSeen: Date

    var id: String { sessionId }
}

/// Minimal shape of a transcript line; everything optional, only assistant lines are used.
private struct TranscriptLine: Decodable {
    var type: String?
    var timestamp: Date?
    var uuid: String?
    var requestId: String?
    var sessionId: String?
    var cwd: String?
    var gitBranch: String?
    var slug: String?
    var message: Message?

    struct Message: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?

        struct Usage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?
            var cacheCreationInputTokens: Int?
            var cacheReadInputTokens: Int?
            var cacheCreation: CacheCreation?
            /// Per-iteration usage of the same response; a few lines carry the totals only here.
            var iterations: [Usage]?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreation = "cache_creation"
                case iterations
            }

            var input: Int { inputTokens ?? 0 }
            var output: Int { outputTokens ?? 0 }
            var cacheRead: Int { cacheReadInputTokens ?? 0 }

            /// (5 m, 1 h) cache writes: the per-TTL object when present, else the flat count as 5 m.
            var cacheWrites: (Int, Int) {
                if let cc = cacheCreation, cc.ephemeral5m != nil || cc.ephemeral1h != nil {
                    return (cc.ephemeral5m ?? 0, cc.ephemeral1h ?? 0)
                }
                return (cacheCreationInputTokens ?? 0, 0)
            }

            var total: Int { input + output + cacheRead + cacheWrites.0 + cacheWrites.1 }

            /// The top-level counts, or the sum of `iterations` when that carries more: a few
            /// responses arrive with zeroed top-level fields and the real numbers one level down.
            var effective: (input: Int, output: Int, write5m: Int, write1h: Int, cacheRead: Int) {
                let top = (input, output, cacheWrites.0, cacheWrites.1, cacheRead)
                guard let iterations, !iterations.isEmpty else { return top }
                let summed = iterations.reduce(into: (0, 0, 0, 0, 0)) { acc, it in
                    let writes = it.cacheWrites
                    acc.0 += it.input; acc.1 += it.output; acc.2 += writes.0; acc.3 += writes.1; acc.4 += it.cacheRead
                }
                let summedTotal = summed.0 + summed.1 + summed.2 + summed.3 + summed.4
                return summedTotal > total ? summed : top
            }

            struct CacheCreation: Decodable {
                var ephemeral5m: Int?
                var ephemeral1h: Int?
                enum CodingKeys: String, CodingKey {
                    case ephemeral5m = "ephemeral_5m_input_tokens"
                    case ephemeral1h = "ephemeral_1h_input_tokens"
                }
            }
        }
    }
}

/// The small `{"type":"…"}` bookkeeping lines Claude Code rewrites every turn.
private struct MetaLine: Decodable {
    var type: String?
    var sessionId: String?
    var aiTitle: String?
    var agentColor: String?
    var lastPrompt: String?
}

enum TokenScanError: LocalizedError, Equatable {
    case missingRoot(String)

    var errorDescription: String? {
        switch self {
        case .missingRoot(let path): return "No Claude Code transcripts at \(path)."
        }
    }
}

// MARK: - Scanner

/// Reads `~/.claude/projects` incrementally: per-file byte offsets plus an id-keyed record map,
/// both persisted so a poll only reads the bytes appended since the last one.
actor TokenScanner {
    let root: URL
    /// nil disables persistence (tests).
    let cacheURL: URL?

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)
    static var defaultCacheURL: URL { AppPaths.supportDirectory.appendingPathComponent("tokens.json") }

    init(root: URL = TokenScanner.defaultRoot, cacheURL: URL? = TokenScanner.defaultCacheURL) {
        self.root = root
        self.cacheURL = cacheURL
    }

    /// Bumped whenever the cache shape changes, which forces a full rescan on the next launch.
    /// 2: records carry a session id and the cache holds session metadata.
    static let cacheVersion = 2

    private struct Cache: Codable {
        static let currentVersion = TokenScanner.cacheVersion
        var version = currentVersion
        /// Symlink-resolved absolute path -> bytes consumed; always ends just after a newline.
        var offsets: [String: UInt64] = [:]
        /// Message id -> record.
        var records: [String: TokenRecord] = [:]
        /// Session id -> what its transcript says about it.
        var sessions: [String: SessionMeta] = [:]
    }

    /// Loaded lazily on the first scan so init stays cheap and synchronous.
    private var cache: Cache?
    private var dirty = false
    private let decoder = UsageClient.makeDecoder()

    private static let chunkSize = 1 << 20
    /// Longest line the scanner is willing to hold while waiting for its newline (real lines top out near 2 MB).
    private static let maxLineBytes = 64 << 20
    private static let newline: UInt8 = 0x0A
    /// Cheap raw prefilter; the files are compact JSON so the key and value are adjacent.
    private static let assistantMarker = Data("\"type\":\"assistant\"".utf8)
    /// Bookkeeping lines put `type` first, so a prefix check picks them out without decoding.
    private static let metaPrefixes = ["ai-title", "agent-color", "last-prompt"].map { Data("{\"type\":\"\($0)\"".utf8) }
    private static let maxPromptLength = 120

    /// Scans, prunes anything older than `retainSince`, saves the cache when dirty,
    /// and returns every retained record.
    func scan(retainSince: Date) throws -> [TokenRecord] {
        var cache = self.cache ?? loadCache()
        var seen = Set<String>()

        for file in try enumerate() {
            // Every line in a file is older than its mtime, so nothing inside can be in-window.
            guard file.mtime >= retainSince else { continue }
            seen.insert(file.path)

            var offset = cache.offsets[file.path] ?? 0
            // Replaced or truncated: re-read from the top, id dedup keeps that idempotent.
            if file.size < offset { offset = 0 }
            if file.size > offset {
                offset = consume(file.url, from: offset) { line in
                    ingest(line, into: &cache, retainSince: retainSince)
                }
            }
            if cache.offsets[file.path] != offset {
                cache.offsets[file.path] = offset
                dirty = true
            }
        }

        // Prune aged records and offsets for files that are gone or aged out. A file appended
        // to again later is re-read from 0; the timestamp filter and dedup keep that correct.
        let before = cache.records.count
        cache.records = cache.records.filter { $0.value.timestamp >= retainSince }
        if cache.records.count != before { dirty = true }
        let sessionsBefore = cache.sessions.count
        cache.sessions = cache.sessions.filter { $0.value.lastSeen >= retainSince }
        if cache.sessions.count != sessionsBefore { dirty = true }
        let stale = cache.offsets.keys.filter { !seen.contains($0) }
        for path in stale {
            cache.offsets.removeValue(forKey: path)
            dirty = true
        }

        self.cache = cache
        if dirty {
            saveCache(cache)
            dirty = false
        }
        return Array(cache.records.values)
    }

    /// Session metadata gathered by the scans so far (empty before the first scan).
    func sessions() -> [SessionMeta] {
        Array((cache?.sessions ?? [:]).values)
    }

    // MARK: - files

    private struct Entry {
        var url: URL
        var path: String
        var size: UInt64
        var mtime: Date
    }

    /// Every `*.jsonl` under the root at any depth (subagents nest two and four levels down), sorted by path.
    private func enumerate() throws -> [Entry] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TokenScanError.missingRoot(root.path)
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else {
            throw TokenScanError.missingRoot(root.path)
        }
        var entries: [Entry] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            // Resolved, so the key is the same however the root was spelled (/var vs /private/var).
            entries.append(Entry(url: url,
                                 path: url.resolvingSymlinksInPath().path,
                                 size: UInt64(values.fileSize ?? 0),
                                 mtime: values.contentModificationDate ?? .distantPast))
        }
        return entries.sorted { $0.path < $1.path }
    }

    /// Reads from `start` in 1 MB chunks and hands out complete lines only. Returns the offset just
    /// after the last newline consumed; a partial trailing line waits for the next scan.
    /// A file that cannot be opened is left alone (its offset stays put).
    private func consume(_ url: URL, from start: UInt64, handle: (Data) -> Void) -> UInt64 {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return start }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: start)) != nil else { return start }

        var consumed = start
        // Bytes after the last newline seen so far. Data slices keep their parent's indices,
        // so every position below is relative to `pending.startIndex`.
        var pending = Data()
        // The chunk is autoreleased; without a pool every chunk of a file stays resident until
        // the scan returns (hundreds of MB for a busy session file instead of a few).
        while let chunk = autoreleasepool(invoking: { try? fh.read(upToCount: Self.chunkSize) }), !chunk.isEmpty {
            // Newlines before the old tail were already searched.
            var searchFrom = pending.endIndex
            pending.append(chunk)
            var lineStart = pending.startIndex
            while let nl = pending[searchFrom...].firstIndex(of: Self.newline) {
                handle(Data(pending[lineStart..<nl]))
                lineStart = nl + 1
                searchFrom = lineStart
            }
            consumed += UInt64(lineStart - pending.startIndex)
            pending.removeSubrange(pending.startIndex..<lineStart)
            // A line that never ends (a file with no trailing newline for many MB) is not buffered
            // without limit; the file is left at `consumed` and retried next poll.
            if pending.count > Self.maxLineBytes { break }
        }
        return consumed
    }

    // MARK: - lines

    private func ingest(_ line: Data, into cache: inout Cache, retainSince: Date) {
        if Self.metaPrefixes.contains(where: { line.starts(with: $0) }) {
            ingestMeta(line, into: &cache)
            return
        }
        guard line.range(of: Self.assistantMarker) != nil,
              let entry = try? decoder.decode(TranscriptLine.self, from: line),
              entry.type == "assistant",
              let message = entry.message,
              let usage = message.usage,
              let timestamp = entry.timestamp,
              timestamp >= retainSince,
              let key = message.id ?? entry.requestId ?? entry.uuid
        else { return }

        let model = (message.model ?? "").replacingOccurrences(of: "[1m]", with: "")
        guard model != "<synthetic>" else { return }

        if let sessionId = entry.sessionId {
            update(session: sessionId, in: &cache) { meta in
                meta.firstSeen = min(meta.firstSeen, timestamp)
                meta.lastSeen = max(meta.lastSeen, timestamp)
                // The first cwd is where the session was started; later ones follow the shell's cd.
                if meta.cwd == nil, let cwd = entry.cwd { meta.cwd = cwd }
                if let branch = entry.gitBranch { meta.gitBranch = branch }
                if let slug = entry.slug { meta.slug = slug }
            }
        }

        let counts = usage.effective
        let record = TokenRecord(timestamp: timestamp,
                                 model: model,
                                 input: counts.input,
                                 output: counts.output,
                                 cacheWrite5m: counts.write5m,
                                 cacheWrite1h: counts.write1h,
                                 cacheRead: counts.cacheRead,
                                 sessionId: entry.sessionId)

        // Block lines of one response repeat the same usage; forked sessions copy lines,
        // sometimes with zeroed usage. The larger total wins either way.
        if let old = cache.records[key], old.total >= record.total { return }
        cache.records[key] = record
        dirty = true
    }

    /// Title, colour and last prompt: the latest line wins, and the prompt is clipped because a
    /// pasted prompt can run to kilobytes.
    private func ingestMeta(_ line: Data, into cache: inout Cache) {
        guard let entry = try? decoder.decode(MetaLine.self, from: line),
              let sessionId = entry.sessionId else { return }
        update(session: sessionId, in: &cache) { meta in
            if let title = entry.aiTitle { meta.title = title }
            if let color = entry.agentColor { meta.color = color }
            if let prompt = entry.lastPrompt {
                let flat = prompt.replacingOccurrences(of: "\n", with: " ")
                meta.lastPrompt = flat.count > Self.maxPromptLength ? String(flat.prefix(Self.maxPromptLength)) + "…" : flat
            }
        }
    }

    /// A session first seen through a bookkeeping line has no timestamps yet; `distantFuture` /
    /// `distantPast` let the first assistant line's min/max set them.
    private func update(session id: String, in cache: inout Cache, _ change: (inout SessionMeta) -> Void) {
        var meta = cache.sessions[id] ?? SessionMeta(sessionId: id, firstSeen: .distantFuture, lastSeen: .distantPast)
        change(&meta)
        if meta != cache.sessions[id] {
            cache.sessions[id] = meta
            dirty = true
        }
    }

    // MARK: - cache

    /// Decode failure or a version mismatch means a full first scan.
    private func loadCache() -> Cache {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let cache = try? decoder.decode(Cache.self, from: data),
              cache.version == Cache.currentVersion else { return Cache() }
        return cache
    }

    private func saveCache(_ cache: Cache) {
        guard let cacheURL else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
