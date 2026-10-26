import CryptoKit
import Foundation

/// Where Claude Code keeps its state: `~/.claude` unless the Claude setting names another folder
/// (the one a `CLAUDE_CONFIG_DIR` points `claude` at). Every reader of that state, the credential,
/// the transcripts, the session registry and the folder watcher, asks this one value, so the
/// setting moves them all together. A plain value: resolved from the saved setting on each use,
/// so a change applies to the next refresh without a restart.
struct ClaudeFolder: Equatable, Sendable {
    /// Claude Code's Keychain service for the default folder.
    static let baseService = "Claude Code-credentials"

    /// The setting as typed, trimmed; empty means the default folder.
    let configured: String
    let home: String
    let supportDirectory: URL

    init(configured: String = "", home: String = NSHomeDirectory(), supportDirectory: URL = AppPaths.supportDirectory) {
        self.configured = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        self.home = home
        self.supportDirectory = supportDirectory
    }

    /// The folder named by the saved setting.
    static func current(defaults: UserDefaults = Preferences.defaults) -> ClaudeFolder {
        ClaudeFolder(configured: defaults.string(forKey: Preferences.Key.claudeFolder) ?? "")
    }

    // MARK: - resolution

    /// The default folder, `<home>/.claude`.
    var defaultPath: String { home + "/.claude" }

    /// The folder in use: tilde expanded, no trailing slash, the default when nothing is set.
    var path: String {
        guard !configured.isEmpty else { return defaultPath }
        return Self.withoutTrailingSlash(AppConfig.expand(configured, home: home))
    }

    /// True when the setting names a folder other than the default one. Naming `~/.claude`
    /// explicitly changes nothing: `claude` is then run without `CLAUDE_CONFIG_DIR`.
    var isCustom: Bool { path != defaultPath }

    /// `CLAUDE_CONFIG_DIR` for a `claude` the app starts; nil for the default folder.
    var claudeConfigDir: String? { isCustom ? path : nil }

    var environment: [String: String] { claudeConfigDir.map { ["CLAUDE_CONFIG_DIR": $0] } ?? [:] }

    var credentialsFile: URL { URL(fileURLWithPath: path + "/.credentials.json") }
    var projectsRoot: URL { URL(fileURLWithPath: path + "/projects", isDirectory: true) }
    var sessionsRoot: URL { URL(fileURLWithPath: path + "/sessions", isDirectory: true) }
    /// Where `claude migrate-installer` puts the local install.
    var localBinary: String { path + "/local/claude" }

    /// One scan cache per folder, so a record scanned under one never shows under another.
    var tokenCacheURL: URL {
        supportDirectory.appendingPathComponent(isCustom ? "tokens-\(Self.hash8(path)).bin" : "tokens.bin")
    }

    // MARK: - Keychain

    /// The services to try for this folder's credential, in order. The default folder has the plain
    /// one. A custom folder has only suffixed ones: the plain item is another account's login, so it
    /// is never a fallback. The suffix hashes the path Claude Code was started with, so the resolved
    /// path comes first and the path exactly as typed second when the two differ.
    var keychainServices: [String] {
        guard isCustom else { return [Self.baseService] }
        var services = [Self.keychainService(forConfigDir: path)]
        let typed = Self.keychainService(forConfigDir: configured)
        if !services.contains(typed) { services.append(typed) }
        return services
    }

    /// `Claude Code-credentials`, plus `-<hash8>` for a `CLAUDE_CONFIG_DIR`, where hash8 is the first
    /// 8 hex digits of the SHA-256 of the directory's NFC UTF-8 bytes.
    static func keychainService(forConfigDir dir: String?) -> String {
        guard let dir else { return baseService }
        return baseService + "-" + hash8(dir)
    }

    static func hash8(_ text: String) -> String {
        SHA256.hash(data: Data(text.precomposedStringWithCanonicalMapping.utf8))
            .prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - paths

    private static func withoutTrailingSlash(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
