import CoreServices
import Foundation
import os

/// Decides when a filesystem event under a watched root should turn into an actual refresh.
/// Pure and driven by an injectable clock so tests do not need real timers: something outside
/// (an `ActivityWatcher`'s callback) calls `activityDetected()` on every event, and a periodic
/// driver calls `checkAndFire()`; this type alone decides whether that poll is actually due.
///
/// Two rules, both requested for the "live refresh" feature: a burst of writes coalesces into
/// one refresh after a `quietPeriod` of silence, and no two of this scheduler's fetches ever run
/// closer together than `minimumFetchInterval`, so a chatty transcript cannot out-poll the
/// popover's own stale window.
///
/// Main-actor isolated so the compiler, not convention, guarantees `activityDetected()` (from the
/// watcher's main-queue FSEvents callback) and `checkAndFire()` (from the pump timer) never race.
@MainActor
final class ActivityRefreshScheduler {
    /// How long to wait after the last event before firing.
    static let quietPeriod: TimeInterval = 2
    /// The floor between any two fetches this scheduler triggers.
    static let minimumFetchInterval: TimeInterval = 15

    private let now: () -> Date
    private let onFire: () -> Void
    private(set) var pendingFireAt: Date?
    private(set) var lastFetchAt: Date?

    /// `initialLastFetchAt` lets a caller seed the floor from a fetch that already happened
    /// (the store's own launch refresh) so the very first activity event after launch still
    /// respects the 15 second floor instead of firing immediately.
    init(now: @escaping () -> Date = Date.init, initialLastFetchAt: Date? = nil, onFire: @escaping () -> Void) {
        self.now = now
        self.lastFetchAt = initialLastFetchAt
        self.onFire = onFire
    }

    /// Call on every filesystem event. Pushes the pending fire out to the quiet period from now,
    /// floored so it never lands sooner than the minimum fetch interval after the last fetch.
    /// Repeated calls before the pending time replace it, coalescing a burst into one fire.
    func activityDetected() {
        let current = now()
        var fireAt = current.addingTimeInterval(Self.quietPeriod)
        if let lastFetchAt {
            fireAt = max(fireAt, lastFetchAt.addingTimeInterval(Self.minimumFetchInterval))
        }
        pendingFireAt = fireAt
    }

    /// Called periodically by the driver. Fires, and clears the pending fire, if it is due.
    /// Returns whether it fired, mostly so tests can assert on it directly.
    @discardableResult
    func checkAndFire() -> Bool {
        let current = now()
        guard let pendingFireAt, current >= pendingFireAt else { return false }
        self.pendingFireAt = nil
        lastFetchAt = current
        onFire()
        return true
    }
}

/// Watches a set of directory roots for filesystem activity and calls `onChange` (coalesced by
/// FSEvents itself at a short latency) whenever anything under them changes. Used to notice a
/// fresh Claude Code transcript or Antigravity conversation write so the usage stores can refresh
/// without waiting for the next poll.
///
/// The stream is scheduled on the main queue, so `onChange` is a main-actor closure and the C
/// callback asserts that isolation before calling it: moving the stream to another queue would
/// trap on the first event rather than silently race the scheduler behind it.
final class ActivityWatcher {
    private static let log = Logger(subsystem: "io.github.dragonf1.aiusagebar", category: "activity")

    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    private init(roots: [String], onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<ActivityWatcher>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { watcher.onChange() }
            },
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    /// Builds a watcher for every root that exists, skipping (and logging once) any that do not,
    /// and resolving symlinks first: `~/.gemini` is one, and FSEvents reports on real paths, so
    /// watching the symlink itself would never see events. Returns nil if nothing was watchable.
    static func forRoots(_ roots: [URL], onChange: @escaping @MainActor () -> Void) -> ActivityWatcher? {
        let fm = FileManager.default
        let existing = roots.compactMap { root -> String? in
            let resolved = root.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                log.info("activity watcher skipped missing root: \(resolved.path, privacy: .public)")
                return nil
            }
            return resolved.path
        }
        guard !existing.isEmpty else { return nil }
        return ActivityWatcher(roots: existing, onChange: onChange)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
