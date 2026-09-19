import Foundation

enum RefreshError: LocalizedError, Equatable {
    case noRefreshToken
    case disabled
    case throttled
    case cliOwnsRefresh
    case cliMissing
    case cliDidNotRefresh
    case cliFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRefreshToken: return "No refresh token stored. Run `claude` once to sign in again."
        case .disabled:
            return "Claude Code's token has expired. Run `claude` to refresh it, or set {\"claude\": {\"refresh\": true}} in ~/.config/aiusagebar/config.json to let this app start `claude` for you."
        case .throttled: return "Refresh attempted less than a minute ago."
        case .cliOwnsRefresh: return "A `claude` session is running; waiting for it to refresh the token."
        case .cliMissing: return "Claude Code's token has expired and no `claude` binary was found to refresh it."
        case .cliDidNotRefresh: return "Started `claude` but the token stayed expired. Run `claude` yourself; it may want a fresh sign-in."
        case .cliFailed(let why): return "Could not start `claude` to refresh the token: \(why)"
        }
    }
}

/// Gets Claude Code to refresh its own token; this app never writes the credential. With
/// `config.json` opting in, an expired token makes the app start `claude` on a pseudo-terminal in
/// an empty folder of its own, wait for Claude Code's startup to rotate the credential (it
/// refreshes an expired token before its first request), quit it, and read the item again.
/// Refresh tokens are single-use, so the CLI stays the only writer; the guards here only avoid
/// starting a second `claude` next to one the user has open that is about to do the same job.
struct OAuthRefresher {
    /// Never start the CLI more often than this.
    static let minInterval: TimeInterval = 60
    /// If the CLI is running and the token only just expired, let that process do it.
    static let cliGrace: TimeInterval = 3 * 60

    var store = CredentialStore()
    var cli: ClaudeCLITouch = ClaudeCLIProbe()
    var enabled: Bool = AppConfig.loadSettings().refreshesClaudeToken
    var isCLIRunning: () -> Bool = { Shell.isRunning(processNamed: "claude") }
    var now: () -> Date = Date.init
    var lastAttempt: () -> Date? = { RefreshStamp.read() }
    var recordAttempt: (Date) -> Void = { RefreshStamp.write($0) }

    /// Returns fresh credentials, or the current ones if somebody else already refreshed.
    func refreshIfNeeded(force: Bool) async throws -> StoredCredentials {
        // Guard 1: re-read right before deciding; the CLI may have refreshed already.
        let current = try store.read()
        if !force && !current.oauth.isExpired(now: now()) { return current }

        guard enabled else { throw RefreshError.disabled }
        guard let refreshToken = current.oauth.refreshToken, !refreshToken.isEmpty else {
            throw RefreshError.noRefreshToken
        }
        // Guard 2: rate guard.
        if let last = lastAttempt(), now().timeIntervalSince(last) < Self.minInterval {
            throw RefreshError.throttled
        }
        // Guard 3: freshly expired + CLI alive = that CLI's job.
        if isCLIRunning(), current.oauth.expiredFor(now: now()) < Self.cliGrace {
            throw RefreshError.cliOwnsRefresh
        }
        recordAttempt(now())

        // The probe stops as soon as the stored access token differs from the one it started with.
        let before = current.oauth.accessToken
        let store = store
        _ = try await cli.run(until: { (try? store.read())?.oauth.accessToken != before })
        let latest = try store.read()
        guard latest.oauth.accessToken != before else { throw RefreshError.cliDidNotRefresh }
        return latest
    }
}

/// Something that starts Claude Code and lets it run until `done` says the credential changed.
/// Returns whether it did; throws when the CLI could not be started at all.
protocol ClaudeCLITouch: Sendable {
    func run(until done: @escaping @Sendable () -> Bool) async throws -> Bool
}

/// Runs the real `claude` on a pty. Claude Code refreshes an expired token during startup, before
/// the folder-trust question is answered, so the common run never gets past that screen: the probe
/// polls the credential, sees it change, cancels the question with Esc and stops the process. If
/// the credential has not moved after `trustAfter` seconds the question is answered "yes" (the
/// folder is an empty one of this app's own) so the session proper starts and makes its first
/// request; then `/exit`. The probe always asks Claude Code to leave on its own before it signals
/// the process group, and it runs Claude Code's classic renderer: the fullscreen one keeps a boot
/// canary in `~/.claude.json` that counts a launch killed before it was healthy as a crash, and two
/// of those turn fullscreen off for the user until they run `/tui fullscreen`. The registry files
/// Claude Code leaves behind for the probe's pid and the probe folder's transcripts (empty
/// sessions, one per run) are removed at the end.
struct ClaudeCLIProbe: ClaudeCLITouch {
    /// Where the probe runs: an empty folder, so the trust question is about nothing.
    static let directory = AppPaths.supportDirectory.appendingPathComponent("claude-probe", isDirectory: true)

    static let candidates: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            home + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home + "/.claude/local/claude",
        ]
    }()

    /// No tools, no MCP servers, no hooks, no Remote Control, classic renderer (see above): the
    /// session is never given a prompt. `--settings` is a per-launch overlay; the user's own settings stay.
    static let arguments = ["--allowed-tools", "", "--strict-mcp-config",
                            "--settings", #"{"remoteControlAtStartup":false,"tui":"default","disableAllHooks":true}"#]

    var binary: String? = ClaudeCLIProbe.locate()
    /// Give up on the credential changing after this long.
    var timeout: TimeInterval = 20
    /// Answer the trust question if the credential has not changed by then.
    var trustAfter: TimeInterval = 7
    var sessionsRoot = SessionRegistry.defaultRoot
    var projectsRoot = TokenScanner.defaultRoot
    /// What the last run saw and did, for working out why a refresh did not happen.
    static var logFile: URL { directory.appendingPathComponent("last-run.txt") }

    /// Where Claude Code keeps the transcripts of sessions run in `folder`: the path with every
    /// character outside A-Z, a-z and 0-9 turned into "-".
    static func transcriptDirectory(for folder: String, under projectsRoot: URL) -> URL {
        let name = String(folder.unicodeScalars.map { s -> Character in
            let v = s.value
            let plain = (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
            return plain ? Character(s) : "-"
        })
        return projectsRoot.appendingPathComponent(name, isDirectory: true)
    }

    static func locate(candidates: [String] = ClaudeCLIProbe.candidates) -> String? {
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        guard let out = try? Shell.run("/usr/bin/which", ["claude"]), out.status == 0 else { return nil }
        let path = out.stdout.trimmed
        return path.isEmpty ? nil : path
    }

    func run(until done: @escaping @Sendable () -> Bool) async throws -> Bool {
        guard let binary else { throw RefreshError.cliMissing }
        let probe = self
        // Blocking reads and sleeps: keep them off every actor.
        return try await Task.detached(priority: .utility) {
            try probe.drive(binary: binary, until: done)
        }.value
    }

    // MARK: - the session

    private func drive(binary: String, until done: () -> Bool) throws -> Bool {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var primary: Int32 = -1
        var secondary: Int32 = -1
        var window = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &window) == 0 else {
            throw RefreshError.cliFailed("openpty failed")
        }
        _ = fcntl(primary, F_SETFL, O_NONBLOCK)
        defer { close(primary) }
        let secondaryHandle = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = Self.arguments
        process.currentDirectoryURL = Self.directory
        process.environment = Self.environment()
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle
        do { try process.run() } catch { throw RefreshError.cliFailed(error.localizedDescription) }
        let pid = process.processIdentifier
        // Its own group, so the helpers the CLI forks go with it.
        _ = setpgid(pid, pid)
        try? secondaryHandle.close()

        var screen = ProbeScreen()
        var trustAnswered = false
        var refreshed = false
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        defer {
            let ending = stop(process, pid: pid, terminal: primary, screen: &screen)
            log(screen, pid: pid, started: started, trustAnswered: trustAnswered, refreshed: refreshed, ending: ending)
        }
        while Date() < deadline, process.isRunning {
            screen.append(Self.readAvailable(primary))
            if done() { refreshed = true; return true }
            if !trustAnswered, screen.showsTrustQuestion, Date().timeIntervalSince(started) >= trustAfter {
                trustAnswered = true
                if screen.trustDefault == .decline {
                    Self.send("\u{1b}[B", to: primary)   // down: onto "Yes, I trust this folder"
                    usleep(300_000)
                }
                Self.send("\r", to: primary)
            }
            usleep(250_000)
        }
        refreshed = done()
        return refreshed
    }

    private func log(_ screen: ProbeScreen, pid: Int32, started: Date, trustAnswered: Bool, refreshed: Bool,
                     ending: String)
    {
        let seconds = Int(Date().timeIntervalSince(started))
        let text = """
        \(started) pid \(pid), \(seconds) s, trust question \(trustAnswered ? "answered" : "left alone"), \
        credential \(refreshed ? "changed" : "unchanged"), \(ending)
        screen: \(screen.text.suffix(2000))

        """
        try? text.write(to: Self.logFile, atomically: true, encoding: .utf8)
    }

    /// How long each polite step gets before the next: Esc, Ctrl-C twice, `/exit`, SIGTERM.
    static let exitWaits: [TimeInterval] = [1.5, 3, 5, 3]

    /// Esc cancels the trust question, Ctrl-C twice or `/exit` ends a started session; each is
    /// given time to finish so Claude Code's own exit hooks run. Only a process that ignores them
    /// all is signalled, and the pid's registry files are removed either way. Returns how the
    /// process ended, for the log; `screen` keeps collecting what the pty shows meanwhile.
    private func stop(_ process: Process, pid: Int32, terminal: Int32, screen: inout ProbeScreen) -> String {
        var ending = "exit clean before stop"
        let steps: [(name: String, keys: () -> Void, grace: TimeInterval)] = [
            ("Esc", { Self.send("\u{1b}", to: terminal) }, Self.exitWaits[0]),
            ("Ctrl-C twice", { Self.send("\u{03}", to: terminal); usleep(300_000); Self.send("\u{03}", to: terminal) },
             Self.exitWaits[1]),
            ("/exit", { Self.type("/exit", to: terminal) }, Self.exitWaits[2]),
        ]
        for step in steps where process.isRunning {
            step.keys()
            Self.wait(for: process, upTo: step.grace, terminal: terminal, screen: &screen)
            ending = "exit clean after \(step.name)"
        }
        for (signal, grace) in [(SIGTERM, Self.exitWaits[3]), (SIGKILL, 0.5)] where process.isRunning {
            if kill(-pid, signal) != 0 { kill(pid, signal) }
            Self.wait(for: process, upTo: grace, terminal: terminal, screen: &screen)
            ending = signal == SIGTERM ? "killed with SIGTERM" : "killed with SIGKILL"
        }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: sessionsRoot.path) {
            for name in names where name.hasPrefix("\(pid).") {
                try? FileManager.default.removeItem(at: sessionsRoot.appendingPathComponent(name))
            }
        }
        try? FileManager.default.removeItem(at: Self.transcriptDirectory(for: Self.directory.path, under: projectsRoot))
        return ending
    }

    /// Polls every 100 ms until the process has exited or `limit` has passed, draining the pty
    /// into `screen` on the way (a full pty buffer would stall the process).
    private static func wait(for process: Process, upTo limit: TimeInterval, terminal: Int32, screen: inout ProbeScreen) {
        let deadline = Date().addingTimeInterval(limit)
        while process.isRunning && Date() < deadline {
            screen.append(readAvailable(terminal))
            usleep(100_000)
        }
        screen.append(readAvailable(terminal))
    }

    private static func send(_ text: String, to fd: Int32) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }

    /// Types `text` one character at a time and then presses Enter. Several characters in one
    /// read look like a paste to Claude Code, and a pasted newline goes into the input instead of
    /// submitting it.
    private static func type(_ text: String, to fd: Int32) {
        for character in text {
            send(String(character), to: fd)
            usleep(40_000)
        }
        usleep(250_000)
        send("\r", to: fd)
    }

    /// Everything the non-blocking pty has right now; empty when it has nothing.
    private static func readAvailable(_ fd: Int32) -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
            if n < buffer.count { break }
        }
        return out
    }

    /// The app's environment without anything that would point Claude Code at another account
    /// or make it think it is nested in a session, plus the paths `claude` is usually installed under.
    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        for key in env.keys where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_CODE_") || key == "CLAUDECODE" {
            env.removeValue(forKey: key)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init))
            .joined(separator: ":")
        env["HOME"] = env["HOME"] ?? home
        env["TERM"] = "xterm-256color"
        env["DISABLE_AUTOUPDATER"] = "1"
        env["PWD"] = directory.path
        return env
    }
}

/// What the probe has seen on its terminal, with the escape sequences and all whitespace
/// dropped: Claude Code's renderer positions words with cursor moves, so the plain text of
/// "Yes, I trust this folder" arrives as "Yes,Itrustthisfolder".
struct ProbeScreen {
    enum TrustDefault { case accept, decline }

    /// Only the tail is kept; the screens of interest fit in it many times over.
    static let keep = 8192

    private(set) var text = ""

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        text += Self.strip(String(decoding: data, as: UTF8.self))
        if text.count > Self.keep { text = String(text.suffix(Self.keep)) }
    }

    var showsTrustQuestion: Bool {
        text.contains("trustthisfolder") || text.contains("Doyoutrustthefiles")
    }

    /// Which answer the selection marker sits on in the latest draw; nil when there is no marker.
    var trustDefault: TrustDefault? {
        guard let marker = text.range(of: "❯", options: .backwards) else { return nil }
        let after = text[marker.upperBound...].prefix(12)
        if after.hasPrefix("No") { return .decline }
        if after.hasPrefix("Yes") { return .accept }
        return nil
    }

    /// Drops ANSI escape sequences (CSI, OSC, charset designations and the two-byte ones) and every whitespace character.
    static func strip(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.utf8.count)
        var scalars = raw.unicodeScalars.makeIterator()
        while let s = scalars.next() {
            if s == "\u{1b}" {
                guard let kind = scalars.next() else { break }
                switch kind {
                case "[":
                    // CSI: parameter and intermediate bytes, then one final byte in 0x40...0x7E.
                    while let c = scalars.next(), !(0x40...0x7E).contains(c.value) {}
                case "]":
                    // OSC: up to BEL or ST (ESC \).
                    while let c = scalars.next() {
                        if c == "\u{7}" { break }
                        if c == "\u{1b}" { _ = scalars.next(); break }
                    }
                case _ where (0x20...0x2F).contains(kind.value):
                    // ESC + intermediate bytes (charset designations like "ESC ( B"), then one final byte.
                    while let c = scalars.next(), (0x20...0x2F).contains(c.value) {}
                default:
                    break   // two-byte sequence, the second byte just consumed
                }
                continue
            }
            if s.properties.isWhitespace || s.value < 0x20 || s.value == 0x7F { continue }
            out.unicodeScalars.append(s)
        }
        return out
    }
}

/// Timestamp of the last refresh attempt, kept on disk so relaunches stay throttled too.
enum RefreshStamp {
    static var url: URL { AppPaths.supportDirectory.appendingPathComponent("refresh.stamp") }

    static func read() -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    static func write(_ date: Date) {
        try? FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
