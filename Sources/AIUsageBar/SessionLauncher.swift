import Foundation

/// Reopens a session from the sessions window. A closed session comes back in a new Terminal
/// window running `claude --resume <id>` in its own folder, or, when `~/.config/aiusagebar/config.json`
/// names a launcher script, through that script with `CLAUDE_RESUME` and `CLAUDE_LAUNCH_DIR` in
/// its environment (plus whatever its `env_file` exports), so a personal launcher's flags apply.
/// An open session has its Terminal window raised instead, because a second `claude` on the same
/// id would fork the conversation, not join it. One running inside tmux (ccmux, for one) gets the
/// Terminal tab attached to its tmux session raised, or a new window attached to that session.
struct SessionLauncher: Sendable {
    struct Command: Equatable, Sendable {
        var executable: String
        var arguments: [String]
        var environment: [String: String] = [:]
    }

    enum Failure: LocalizedError, Equatable {
        case noWorkingDirectory(String?)
        case noLauncher(String)
        case noTTY(Int32)
        case noTerminalWindow(Int32, String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noWorkingDirectory(let cwd):
                return "Its folder is gone: \(cwd ?? "unknown"). Claude Code keeps transcripts per folder, so it cannot be resumed."
            case .noLauncher(let path):
                return "The launcher named in config.json is missing: \(path)."
            case .noTTY(let pid):
                return "PID \(pid) has no terminal; it was not started from a Terminal window."
            case .noTerminalWindow(let pid, let tty):
                return "No Terminal.app window is running PID \(pid) (\(tty)). Look for it in another terminal app."
            case .failed(let message):
                return message
            }
        }
    }

    /// Script that opens the session instead of the plain Terminal command; nil means the default.
    var launcher: URL?
    /// `KEY=value` lines exported into the launcher's environment first; ignored without a launcher.
    var envFile: URL?
    var fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    /// Runs a command and returns its stdout; throws `Failure.failed` with stderr on a bad exit.
    var run: @Sendable (Command) async throws -> String = SessionLauncher.execute

    init(settings: AppConfig.Settings.Resume? = AppConfig.loadSettings().resume) {
        launcher = settings?.launcher.map { URL(fileURLWithPath: AppConfig.expand($0)) }
        envFile = settings?.envFile.map { URL(fileURLWithPath: AppConfig.expand($0)) }
    }

    // MARK: - closed sessions

    func resume(_ row: SessionRow) async throws {
        _ = try await run(try resumeCommand(sessionId: row.id, cwd: row.cwd))
    }

    /// Default: Terminal opens a new window that changes into the session's folder and runs
    /// `claude --resume <id>` there (transcripts live per folder). With a configured launcher:
    /// `bash -c` that exports the env file (`set -a` exports every line), then execs the launcher
    /// with the session and its folder in the environment. No colour is passed either way: Claude
    /// Code reads the session's own colour back from the transcript on `--resume`.
    func resumeCommand(sessionId: String, cwd: String?) throws -> Command {
        guard let cwd, fileExists(cwd) else { throw Failure.noWorkingDirectory(cwd) }
        guard let launcher else {
            let script = Self.terminalScript(cwd: cwd, sessionId: sessionId)
            return Command(executable: "/usr/bin/osascript", arguments: ["-e", script])
        }
        guard fileExists(launcher.path) else { throw Failure.noLauncher(launcher.path) }
        var script = ""
        if let envFile {
            script += "set -a; [ -f \(Self.quoted(envFile.path)) ] && . \(Self.quoted(envFile.path)); set +a; "
        }
        script += "exec \(Self.quoted(launcher.path))"
        return Command(executable: "/bin/bash", arguments: ["-c", script],
                       environment: ["CLAUDE_RESUME": sessionId, "CLAUDE_LAUNCH_DIR": cwd])
    }

    /// AppleScript for the default resume: `do script` opens a new Terminal window running the
    /// command in a login shell, so `claude` resolves through the user's own PATH.
    static func terminalScript(cwd: String, sessionId: String) -> String {
        let shell = "cd \(quoted(cwd)) && claude --resume \(quoted(sessionId))"
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"Terminal\"\ndo script \"\(escaped)\"\nactivate\nend tell"
    }

    /// Single-quoted for the shell; the only character that needs care inside single quotes is `'`.
    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - open sessions

    func focus(_ row: SessionRow) async throws {
        guard let pid = row.live?.pid else { return try await resume(row) }
        let ps = try await run(Command(executable: "/bin/ps", arguments: ["-o", "tty=", "-p", String(pid)]))
        guard let tty = Self.tty(fromPS: ps) else { throw Failure.noTTY(pid) }
        if try await raiseTerminalTab(tty: tty) { return }
        // Inside tmux, claude's tty is a tmux pane; the Terminal tab is on the attached client's tty.
        guard let tmux = Self.tmuxPaths.first(where: fileExists),
              let panes = try? await run(Command(executable: tmux, arguments: ["list-panes", "-a", "-F", "#{pane_tty}\t#{session_name}"])),
              let session = Self.tmuxSession(tty: tty, panes: panes)
        else { throw Failure.noTerminalWindow(pid, tty) }
        let clients = (try? await run(Command(executable: tmux, arguments: ["list-clients", "-t", "=" + session, "-F", "#{client_tty}"]))) ?? ""
        for client in clients.split(whereSeparator: \.isNewline) {
            if try await raiseTerminalTab(tty: String(client)) { return }
        }
        _ = try await run(Command(executable: "/usr/bin/osascript", arguments: ["-e", Self.attachScript(tmux: tmux, session: session)]))
    }

    private func raiseTerminalTab(tty: String) async throws -> Bool {
        let found = try await run(Command(executable: "/usr/bin/osascript", arguments: ["-e", Self.focusScript(tty: tty)]))
        return found.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    /// Homebrew on Apple Silicon, then Intel; the app's own PATH has neither.
    static let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]

    /// The tmux session whose pane sits on `tty`, from `list-panes -a -F '#{pane_tty}<tab>#{session_name}'`.
    static func tmuxSession(tty: String, panes: String) -> String? {
        for line in panes.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2, parts[0] == tty { return String(parts[1]) }
        }
        return nil
    }

    /// A new Terminal window attached to the session (`=` makes tmux match the name exactly).
    /// Plain `attach` leaves any other client attached, the same as ccmux's default mirror mode.
    static func attachScript(tmux: String, session: String) -> String {
        let shell = "\(quoted(tmux)) attach-session -t \(quoted("=" + session))"
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"Terminal\"\ndo script \"\(escaped)\"\nactivate\nend tell"
    }

    /// `ps -o tty=` prints "ttys004", or "??" for a process with no controlling terminal.
    static func tty(fromPS output: String) -> String? {
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return "/dev/" + name
    }

    /// Selects the tab on that tty, brings its window to the front and Terminal with it.
    static func focusScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "none"
        """
    }

    // MARK: - process

    @Sendable
    private static func execute(_ command: Command) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { $1 }
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { process in
                let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Failure.failed(message.isEmpty
                        ? "\(command.executable) exited with status \(process.terminationStatus)" : message))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: Failure.failed(error.localizedDescription))
            }
        }
    }
}
