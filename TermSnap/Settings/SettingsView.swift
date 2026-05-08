import SwiftUI
import AppKit
import Combine

struct SettingsView: View {
    @State private var saveFormat = AppSettings.saveFormat
    @State private var saveDirectory = AppSettings.saveDirectory
    @State private var shortcutFullScreen = AppSettings.shortcutFullScreen
    @State private var shortcutArea = AppSettings.shortcutArea
    @State private var shortcutWindow = AppSettings.shortcutWindow

    var body: some View {
        Form {
            Section {
                Picker("Save Format", selection: $saveFormat) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    Text("Save to:")
                    Text(directoryDisplayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { chooseDirectory() }
                        .fixedSize()
                }
            } header: {
                Label("Export", systemImage: "square.and.arrow.up")
            }

            Section {
                ShortcutRow(label: "Full Screen", shortcut: $shortcutFullScreen)
                ShortcutRow(label: "Area", shortcut: $shortcutArea)
                ShortcutRow(label: "Window", shortcut: $shortcutWindow)
            } header: {
                Label("Shortcuts", systemImage: "keyboard")
            } footer: {
                Text("Click Record then press the key combination you want to use.")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: 380, height: 300)
        .onChange(of: saveFormat) { _, newValue in AppSettings.saveFormat = newValue }
        .onChange(of: saveDirectory) { _, newValue in AppSettings.saveDirectory = newValue }
        .onChange(of: shortcutFullScreen) { _, newValue in AppSettings.shortcutFullScreen = newValue }
        .onChange(of: shortcutArea) { _, newValue in AppSettings.shortcutArea = newValue }
        .onChange(of: shortcutWindow) { _, newValue in AppSettings.shortcutWindow = newValue }
    }

    private var directoryDisplayName: String {
        if saveDirectory.isEmpty { return "Desktop" }
        return URL(fileURLWithPath: saveDirectory).lastPathComponent
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose default save location for screenshots"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                saveDirectory = url.path
            }
        }
    }
}

// MARK: - Shortcut Row

private struct ShortcutRow: View {
    let label: String
    @Binding var shortcut: String
    @State private var isRecording = false
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        HStack {
            Text(label)
            Spacer()

            if isRecording {
                Text("Press shortcut\u{2026}")
                    .foregroundColor(.secondary)
                    .frame(minWidth: 100, alignment: .trailing)
                Button("Cancel") { cancelRecording() }
                    .controlSize(.small)
            } else {
                Text(shortcut.isEmpty ? "None" : shortcut)
                    .foregroundColor(.secondary)
                    .opacity(shortcut.isEmpty ? 0.5 : 1)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 100, alignment: .trailing)
                Button("Record") { startRecording() }
                    .controlSize(.small)
            }
        }
        .onDisappear { cancelRecording() }
    }

    private func startRecording() {
        isRecording = true
        recorder.start { keyString in
            shortcut = keyString
            cancelRecording()
        }
    }

    private func cancelRecording() {
        recorder.stop()
        isRecording = false
    }
}

// MARK: - Shortcut Recorder

private class ShortcutRecorder: NSObject, ObservableObject {
    private var monitor: Any?
    private var handler: ((String) -> Void)?

    func start(handler: @escaping (String) -> Void) {
        self.handler = handler
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasModifier = !modifiers.isDisjoint(with: [.command, .option, .control, .shift])
            let chars = event.charactersIgnoringModifiers ?? ""

            guard hasModifier else { return nil }
            guard let char = chars.first, char.isLetter || char.isNumber else { return nil }

            var parts: [String] = []
            if modifiers.contains(.control) { parts.append("\u{2303}") }
            if modifiers.contains(.option)  { parts.append("\u{2325}") }
            if modifiers.contains(.shift)   { parts.append("\u{21E7}") }
            if modifiers.contains(.command) { parts.append("\u{2318}") }
            parts.append(char.uppercased())

            handler(parts.joined())
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        handler = nil
    }

    deinit { stop() }
}
