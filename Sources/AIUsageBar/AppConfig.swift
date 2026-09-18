import Foundation

/// Settings the app cannot work out on its own, read from `~/.config/aiusagebar/`. Every file is
/// optional and none of them is ever written by the app; a missing file means the built-in default.
enum AppConfig {
    static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/aiusagebar", isDirectory: true)
    static let settingsFile = directory.appendingPathComponent("config.json")
    static let antigravityClientFile = directory.appendingPathComponent("antigravity-client.json")

    /// `config.json`:
    /// `{"claude": {"refresh": true},
    ///   "resume": {"launcher": "~/bin/my-claude.sh", "env_file": "~/bin/my-claude.env"}}`
    struct Settings: Codable, Equatable {
        struct Claude: Codable, Equatable {
            /// Let the app run Claude Code's refresh-token flow and write the new tokens into
            /// Claude Code's own credential item when the stored access token has expired.
            /// Off by default: the app then only reads whatever Claude Code keeps fresh.
            var refresh: Bool?
        }
        struct Resume: Codable, Equatable {
            /// Script to run instead of a plain `claude --resume`. It receives `CLAUDE_RESUME`
            /// (the session id) and `CLAUDE_LAUNCH_DIR` (the session's folder) in its environment
            /// and is expected to open the terminal window itself.
            var launcher: String?
            /// `KEY=value` file exported into the launcher's environment before it runs.
            var envFile: String?
        }
        var claude: Claude?
        var resume: Resume?

        var refreshesClaudeToken: Bool { claude?.refresh ?? false }
    }

    /// `antigravity-client.json`: `{"client_id": "...", "client_secret": "..."}`, the OAuth client
    /// Antigravity signs in with. Without it the app never refreshes Antigravity's token and only
    /// reads whatever token Antigravity itself has kept fresh.
    struct OAuthClient: Codable, Equatable {
        var clientId: String
        var clientSecret: String
    }

    static func loadSettings(from url: URL = settingsFile) -> Settings {
        load(Settings.self, from: url) ?? Settings()
    }

    static func loadAntigravityClient(from url: URL = antigravityClientFile) -> OAuthClient? {
        guard let client = load(OAuthClient.self, from: url),
              !client.clientId.isEmpty, !client.clientSecret.isEmpty else { return nil }
        return client
    }

    /// `~` at the start of a configured path means the home folder.
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(type, from: data)
    }
}
