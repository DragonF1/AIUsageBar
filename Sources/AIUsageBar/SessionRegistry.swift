import Foundation

/// One entry of Claude Code's own session registry, `~/.claude/sessions/<pid>.json`: written by
/// each interactive `claude` process and rewritten as it flips between busy and idle.
struct LiveSession: Decodable, Equatable, Sendable, Identifiable {
    var pid: Int32
    var sessionId: String
    var cwd: String?
    /// Milliseconds since the epoch; the current process's start, so a resumed session shows the resume.
    var startedAt: Double?
    var kind: String?
    var status: String?
    var name: String?
    /// "user" when set with /rename, "derived" for the automatic user-hash names.
    var nameSource: String?
    var version: String?
    var updatedAt: Double?

    var id: String { sessionId }
    var isBusy: Bool { status == "busy" }
    var userName: String? { nameSource == "user" ? name : nil }
    var started: Date? { startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// Reads the registry and keeps only sessions whose process is still alive: Claude Code does not
/// always get to delete its file on the way out, so a crashed or killed session lingers.
struct SessionRegistry: Sendable {
    var root: URL
    var isAlive: @Sendable (Int32) -> Bool

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions", isDirectory: true)

    init(root: URL = SessionRegistry.defaultRoot,
         isAlive: @escaping @Sendable (Int32) -> Bool = { kill($0, 0) == 0 }) {
        self.root = root
        self.isAlive = isAlive
    }

    func live() -> [LiveSession] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        let decoder = JSONDecoder()
        var found: [String: LiveSession] = [:]
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(name)),
                  let session = try? decoder.decode(LiveSession.self, from: data),
                  session.kind ?? "interactive" == "interactive",
                  isAlive(session.pid) else { continue }
            // A resumed session can briefly leave two files claiming the same id; keep the newest.
            if let old = found[session.sessionId], (old.updatedAt ?? 0) > (session.updatedAt ?? 0) { continue }
            found[session.sessionId] = session
        }
        return Array(found.values)
    }
}
