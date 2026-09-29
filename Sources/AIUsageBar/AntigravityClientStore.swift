import Foundation
import Security

/// Where the Antigravity OAuth client (id and secret) comes from. Settings saves it in this app's
/// own Keychain item; `~/.config/aiusagebar/antigravity-client.json` keeps working for anyone who
/// set it up that way. The Keychain wins, then the file, then there is no client and the app only
/// reads whatever token Antigravity has kept fresh. The secret goes nowhere else: not UserDefaults,
/// not a log line.
///
/// The reads and writes are closures, so tests hand it an in-memory fake and never touch the
/// real Keychain.
struct AntigravityClientStore {
    static let service = "io.github.dragonf1.aiusagebar"
    static let account = "antigravity-oauth-client"

    enum Source: Equatable {
        case keychain, file, none

        /// The word the Settings status line shows.
        var label: String {
            switch self {
            case .keychain: return "Keychain"
            case .file: return "antigravity-client.json"
            case .none: return "none"
            }
        }
    }

    enum Failure: LocalizedError, Equatable {
        case emptyField
        case keychain(Int32)

        var errorDescription: String? {
            switch self {
            case .emptyField: return "Enter both the client ID and the client secret."
            case .keychain(let status):
                let text = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "The Keychain refused the change: \(text)"
            }
        }
    }

    struct Resolved: Equatable {
        var client: AppConfig.OAuthClient
        var source: Source
    }

    /// The saved item's bytes, or nil when there is none.
    var read: () -> Data?
    var write: (Data) throws -> Void
    /// Removes the item; a missing one is not an error.
    var delete: () throws -> Void
    /// The client `antigravity-client.json` holds, or nil.
    var file: () -> AppConfig.OAuthClient?

    /// The client in force and where it came from; nil when there is none. A damaged or half-empty
    /// Keychain item counts as absent, so the file still gets its turn.
    func resolve() -> Resolved? {
        if let client = keychainClient() { return Resolved(client: client, source: .keychain) }
        if let client = file() { return Resolved(client: client, source: .file) }
        return nil
    }

    var source: Source { resolve()?.source ?? .none }

    /// Stores the client in the Keychain, replacing any earlier one. Both fields are needed; a failed
    /// write leaves the earlier item as it was.
    func save(clientId: String, clientSecret: String) throws {
        let id = clientId.trimmed, secret = clientSecret.trimmed
        guard !id.isEmpty, !secret.isEmpty else { throw Failure.emptyField }
        let data = try JSONSerialization.data(withJSONObject: ["client_id": id, "client_secret": secret],
                                              options: [.sortedKeys])
        try write(data)
    }

    /// Removes the Keychain item, so the file (if any) applies again.
    func clear() throws { try delete() }

    private func keychainClient() -> AppConfig.OAuthClient? {
        guard let data = read() else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let client = try? decoder.decode(AppConfig.OAuthClient.self, from: data),
              !client.clientId.isEmpty, !client.clientSecret.isEmpty else { return nil }
        return client
    }

    // MARK: - the real Keychain

    /// The Keychain and `~/.config/aiusagebar/antigravity-client.json`, as the app runs.
    static let live = AntigravityClientStore(
        read: { readItem() },
        write: { try writeItem($0) },
        delete: { try deleteItem() },
        file: { AppConfig.loadAntigravityClient() })

    private static var itemQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func readItem() -> Data? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func writeItem(_ data: Data) throws {
        let updated = SecItemUpdate(itemQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = itemQuery
            item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.keychain(added) }
        default:
            throw Failure.keychain(updated)
        }
    }

    private static func deleteItem() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }
}
