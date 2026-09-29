import AppKit
import SwiftUI

/// A text setting that saves when Return is pressed or the field loses focus, not on every
/// keystroke: a path half typed is not a path yet, and each save wakes the watchers behind it.
/// Optionally a Choose button next to it for a file or a folder, and a Reset button that empties
/// it. `value` is what is stored now; `commit` receives the trimmed text.
struct SettingsField: View {
    enum Choice { case file, folder }

    var placeholder: String
    var value: String
    var choice: Choice?
    var canReset = false
    var commit: (String) -> Void

    @State private var text: String
    @State private var saved: String
    @FocusState private var focused: Bool

    init(_ placeholder: String, value: String, choice: Choice? = nil, canReset: Bool = false,
         commit: @escaping (String) -> Void) {
        self.placeholder = placeholder
        self.value = value
        self.choice = choice
        self.canReset = canReset
        self.commit = commit
        _text = State(initialValue: value)
        _saved = State(initialValue: value)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
                .onDisappear(perform: save)
            if let choice {
                Button("Choose…") {
                    if let picked = PathPicker.choose(choice, from: text) {
                        text = picked
                        save()
                    }
                }
            }
            if canReset {
                Button("Reset") {
                    text = ""
                    save()
                }
                .disabled(text.isEmpty && saved.isEmpty)
            }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != text { text = trimmed }
        guard trimmed != saved else { return }
        saved = trimmed
        commit(trimmed)
    }
}

/// The standard open panel for one file or one folder. Hidden items are shown: what is being
/// looked for (`~/.claude`, `~/.gemini`, an env file) is usually behind a dot.
enum PathPicker {
    @MainActor
    static func choose(_ choice: SettingsField.Choice, from current: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = choice == .file
        panel.canChooseDirectories = choice == .folder
        panel.canCreateDirectories = choice == .folder
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let start = URL(fileURLWithPath: AppConfig.expand(current.trimmingCharacters(in: .whitespacesAndNewlines)))
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: start.path, isDirectory: &isDirectory) {
            panel.directoryURL = isDirectory.boolValue ? start : start.deletingLastPathComponent()
        } else {
            panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// The small grey line under a setting.
struct SettingCaption: View {
    var text: String
    var isWarning = false

    init(_ text: String, isWarning: Bool = false) {
        self.text = text
        self.isWarning = isWarning
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(isWarning ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}
