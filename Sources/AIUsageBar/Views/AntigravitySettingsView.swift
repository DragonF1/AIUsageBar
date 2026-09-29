import SwiftUI

/// The "Antigravity" tab of the Settings window: the OAuth client that lets the app refresh
/// Antigravity's token, and where that token lives when it is not in the default place.
struct AntigravitySettingsView: View {
    var clients = AntigravityClientStore.live

    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var source: AntigravityClientStore.Source = .none
    @State private var message: String?
    @State private var messageIsError = false
    @State private var tokenFile = Preferences.antigravityTokenFile ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader("OAuth client")
                HStack {
                    Text("Client ID").frame(width: 110, alignment: .leading)
                    TextField("", text: $clientId).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Client secret").frame(width: 110, alignment: .leading)
                    SecureField("", text: $clientSecret).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button("Save", action: save)
                        .disabled(clientId.trimmed.isEmpty || clientSecret.trimmed.isEmpty)
                    Button("Clear", action: clear)
                    Spacer()
                }
                SettingCaption("Active client: \(source.label)")
                if let message { SettingCaption(message, isWarning: messageIsError) }
                SettingCaption("The client Antigravity signs in with. Without one the app only reads the token "
                               + "Antigravity keeps fresh itself. Saved to the macOS Keychain, which wins over "
                               + "~/.config/aiusagebar/antigravity-client.json.")
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionHeader("Token file")
                SettingsField("~/.gemini/jetski-standalone-oauth-token", value: tokenFile, choice: .file, canReset: true) { typed in
                    Preferences.antigravityTokenFile = typed.isEmpty ? nil : typed
                    tokenFile = typed
                }
                SettingCaption("Antigravity's login file. Leave it empty for the default place.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { source = clients.source }
    }

    private func save() {
        do {
            try clients.save(clientId: clientId, clientSecret: clientSecret)
            clientId = ""
            clientSecret = ""
            report("Saved to the Keychain.", isError: false)
        } catch {
            report(error.localizedDescription, isError: true)
        }
    }

    private func clear() {
        do {
            try clients.clear()
            clientId = ""
            clientSecret = ""
            report("Removed the Keychain item.", isError: false)
        } catch {
            report(error.localizedDescription, isError: true)
        }
    }

    private func report(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
        source = clients.source
    }
}
