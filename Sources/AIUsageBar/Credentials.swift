import Foundation

/// The `claudeAiOauth` sub-object of Claude Code's stored credential.
struct OAuthCredential: Equatable {
    var accessToken: String
    var refreshToken: String?
    /// Milliseconds since epoch, as Claude Code stores it.
    var expiresAt: Double?
    var subscriptionType: String?
    var scopes: [String]

    init?(json: [String: Any]) {
        guard let token = json["accessToken"] as? String, !token.isEmpty else { return nil }
        accessToken = token
        refreshToken = json["refreshToken"] as? String
        expiresAt = (json["expiresAt"] as? NSNumber)?.doubleValue
        subscriptionType = json["subscriptionType"] as? String
        scopes = json["scopes"] as? [String] ?? []
    }

    func isExpired(now: Date = Date(), margin: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt / 1000 <= now.timeIntervalSince1970 + margin
    }

    /// How long ago the token expired (negative if still valid).
    func expiredFor(now: Date = Date()) -> TimeInterval {
        guard let expiresAt else { return -.infinity }
        return now.timeIntervalSince1970 - expiresAt / 1000
    }
}

/// Whole credential blob as stored. `raw` keeps every key so a write-back
/// never drops fields this app does not know about.
struct StoredCredentials {
    var raw: [String: Any]
    var oauth: OAuthCredential
    var source: Source

    enum Source: Equatable { case keychain(account: String), file(URL) }

    init?(raw: [String: Any], source: Source) {
        guard let sub = raw["claudeAiOauth"] as? [String: Any],
              let oauth = OAuthCredential(json: sub) else { return nil }
        self.raw = raw
        self.oauth = oauth
        self.source = source
    }

    /// Merge a token-endpoint response into the stored JSON.
    func merging(accessToken: String, refreshToken: String?, expiresIn: Double?, now: Date = Date()) -> StoredCredentials {
        var copy = raw
        var sub = raw["claudeAiOauth"] as? [String: Any] ?? [:]
        sub["accessToken"] = accessToken
        if let refreshToken, !refreshToken.isEmpty { sub["refreshToken"] = refreshToken }
        if let expiresIn { sub["expiresAt"] = Int((now.timeIntervalSince1970 + expiresIn) * 1000) }
        copy["claudeAiOauth"] = sub
        return StoredCredentials(raw: copy, source: source)!
    }

    func serialized() throws -> Data {
        try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

enum CredentialError: LocalizedError {
    case notFound
    case malformed
    case securityFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: return "No Claude Code login found. Run `claude` once and sign in."
        case .malformed: return "Claude Code credential is not in the expected format."
        case .securityFailed(let msg): return "Keychain: \(msg)"
        }
    }
}

/// Reads and writes Claude Code's credential. Goes through `/usr/bin/security`
/// on purpose: that binary is already on the Keychain item's ACL (Claude Code
/// writes through it), so no "allow access" dialog appears.
struct CredentialStore {
    static let service = "Claude Code-credentials"
    static let fallbackFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    var service = CredentialStore.service
    var fallbackFile = CredentialStore.fallbackFile

    func read() throws -> StoredCredentials {
        if let account = try keychainAccount() {
            let out = try Shell.run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
            guard out.status == 0 else { throw CredentialError.securityFailed(out.stderr.trimmed) }
            return try parse(out.stdout.trimmed, source: .keychain(account: account))
        }
        guard let data = FileManager.default.contents(atPath: fallbackFile.path) else {
            throw CredentialError.notFound
        }
        return try parse(String(decoding: data, as: UTF8.self), source: .file(fallbackFile))
    }

    /// Writes back, keeping the source (Keychain item or file) the credential came from.
    /// Backs up the previous JSON so a bad write is recoverable.
    func write(_ creds: StoredCredentials) throws {
        let data = try creds.serialized()
        let json = String(decoding: data, as: UTF8.self)
        try backupCurrent()
        switch creds.source {
        case .keychain(let account):
            let out = try Shell.run("/usr/bin/security", [
                "add-generic-password", "-U", "-a", account, "-s", service, "-w", json,
            ])
            guard out.status == 0 else { throw CredentialError.securityFailed(out.stderr.trimmed) }
        case .file(let url):
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    // MARK: - internals

    private func parse(_ text: String, source: StoredCredentials.Source) throws -> StoredCredentials {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let creds = StoredCredentials(raw: obj, source: source) else {
            throw CredentialError.malformed
        }
        return creds
    }

    /// The `acct` attribute of the Keychain item, needed to rewrite it. nil when absent.
    private func keychainAccount() throws -> String? {
        let out = try Shell.run("/usr/bin/security", ["find-generic-password", "-s", service])
        guard out.status == 0 else { return nil }
        // "acct"<blob>="<account name>"
        guard let range = out.stdout.range(of: #""acct"<blob>=""#) else { return nil }
        let rest = out.stdout[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private func backupCurrent() throws {
        guard let current = try? read(), let data = try? current.serialized() else { return }
        let dir = AppPaths.supportDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("creds.bak")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum AppPaths {
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AIUsageBar", isDirectory: true)
    }()
}

struct Shell {
    struct Output { let status: Int32; let stdout: String; let stderr: String }

    static func run(_ path: String, _ args: [String]) throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Output(status: p.terminationStatus,
                      stdout: String(decoding: o, as: UTF8.self),
                      stderr: String(decoding: e, as: UTF8.self))
    }

    static func isRunning(processNamed name: String) -> Bool {
        guard let out = try? run("/usr/bin/pgrep", ["-x", name]) else { return false }
        return out.status == 0
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
