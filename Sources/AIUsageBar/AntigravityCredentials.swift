import Foundation

enum AntigravityCredentialError: LocalizedError, Equatable {
    case notFound
    case malformed

    var errorDescription: String? {
        switch self {
        case .notFound: return "No Antigravity login found. Open Antigravity and sign in."
        case .malformed: return "Antigravity credential is not in the expected format."
        }
    }
}

/// The token Antigravity's standalone app keeps in `~/.gemini/jetski-standalone-oauth-token`:
/// `{"token": {"access_token", "refresh_token", "expiry", "token_type"}, "auth_method": "consumer"}`.
/// Read-only: this app never writes that file.
struct AntigravityToken: Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiry: Date?

    static let defaultFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/jetski-standalone-oauth-token")

    /// The token file in use: the path saved under "Token file" in Settings (a tilde is expanded),
    /// or the default when none is saved or it is blank.
    static func effectiveFile(defaults: UserDefaults = Preferences.defaults, home: String = NSHomeDirectory()) -> URL {
        let saved = (defaults.string(forKey: Preferences.Key.antigravityTokenFile) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.isEmpty else { return URL(fileURLWithPath: home + "/.gemini/jetski-standalone-oauth-token") }
        return URL(fileURLWithPath: AppConfig.expand(saved, home: home))
    }

    init?(json: [String: Any]) {
        guard let token = json["token"] as? [String: Any],
              let access = token["access_token"] as? String, !access.isEmpty else { return nil }
        accessToken = access
        refreshToken = token["refresh_token"] as? String
        expiry = (token["expiry"] as? String).flatMap(Self.parseExpiry)
    }

    static func read(from url: URL = defaultFile) throws -> AntigravityToken {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw AntigravityCredentialError.notFound
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = AntigravityToken(json: obj) else {
            throw AntigravityCredentialError.malformed
        }
        return token
    }

    /// Unparseable expiry counts as expired so a refresh is attempted rather than a 401.
    func isExpired(now: Date = Date(), margin: TimeInterval = 60) -> Bool {
        guard let expiry else { return true }
        return expiry.timeIntervalSince(now) <= margin
    }

    /// Go writes RFC 3339 with up to nine fractional digits ("2026-09-14T15:09:43.23612-04:00");
    /// ISO8601DateFormatter only takes exactly three, so trim first.
    static func parseExpiry(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        var s = raw
        if let dot = s.firstIndex(of: "."),
           let end = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = s[s.index(after: dot)..<end]
            let trimmed = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            s.replaceSubrange(dot..<end, with: "." + trimmed)
        }
        return fractional.date(from: s) ?? plain.date(from: s) ?? plain.date(from: raw)
    }
}
