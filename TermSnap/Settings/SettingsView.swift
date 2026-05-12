import SwiftUI
import AppKit
import Combine

struct SettingsView: View {
    enum Tab: String, CaseIterable {
        case screenshot = "Screenshot"
        case contextMenu = "Context Menu"
        
        var icon: String {
            switch self {
            case .screenshot: return "camera"
            case .contextMenu: return "computermouse"
            }
        }
        
        var localizedName: String {
            switch self {
            case .screenshot: return NSLocalizedString("Screenshot", comment: "")
            case .contextMenu: return NSLocalizedString("Context Menu", comment: "")
            }
        }
    }
    
    @State private var selectedTab: Tab? = .screenshot
    
    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.localizedName, systemImage: tab.icon)
            }
            .listStyle(.sidebar)
            .navigationTitle(NSLocalizedString("Settings", comment: ""))
        } detail: {
            if let tab = selectedTab {
                switch tab {
                case .screenshot:
                    ScreenshotSettingsView()
                case .contextMenu:
                    ContextMenuSettingsView()
                }
            } else {
                Text(NSLocalizedString("Select a category", comment: ""))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 600, height: 450)
    }
}

// MARK: - Screenshot Settings

struct ScreenshotSettingsView: View {
    @State private var saveFormat = AppSettings.saveFormat
    @State private var saveDirectory = AppSettings.saveDirectory
    @State private var shortcutCapture = AppSettings.shortcutCapture

    var body: some View {
        Form {
            Section {
                Picker(NSLocalizedString("Save Format", comment: ""), selection: $saveFormat) {
                    Text("PNG").tag("png")
                    Text("JPEG").tag("jpeg")
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    Text(NSLocalizedString("Save to:", comment: ""))
                    Text(directoryDisplayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(NSLocalizedString("Choose", comment: "")) { chooseDirectory() }
                        .fixedSize()
                }
            } header: {
                Label(NSLocalizedString("Export", comment: ""), systemImage: "square.and.arrow.up")
            }

            Section {
                ShortcutRow(label: NSLocalizedString("Capture", comment: ""), shortcut: $shortcutCapture)
            } header: {
                Label(NSLocalizedString("Shortcuts", comment: ""), systemImage: "keyboard")
            } footer: {
                Text(NSLocalizedString("Click Record then press the key combination you want to use.", comment: ""))
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("Screenshot", comment: ""))
        .onChange(of: saveFormat) { _, newValue in AppSettings.saveFormat = newValue }
        .onChange(of: saveDirectory) { _, newValue in AppSettings.saveDirectory = newValue }
        .onChange(of: shortcutCapture) { _, newValue in AppSettings.shortcutCapture = newValue }
    }

    private var directoryDisplayName: String {
        if saveDirectory.isEmpty { return NSLocalizedString("Desktop", comment: "") }
        return URL(fileURLWithPath: saveDirectory).lastPathComponent
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = NSLocalizedString("Choose default save location for screenshots", comment: "")
        panel.begin { response in
            if response == .OK, let url = panel.url {
                saveDirectory = url.path
            }
        }
    }
}

// MARK: - Context Menu Settings

struct ContextMenuSettingsView: View {
    @State private var showFinderIcon = AppSettings.showFinderIcon

    var body: some View {
        Form {
            Section {
                Toggle(NSLocalizedString("Show Icon in Context Menu", comment: ""), isOn: $showFinderIcon)
            } header: {
                Label(NSLocalizedString("Finder Extension", comment: ""), systemImage: "macwindow")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("Context Menu", comment: ""))
        .onChange(of: showFinderIcon) { _, newValue in AppSettings.showFinderIcon = newValue }
    }
}

// MARK: - Shortcut Row

struct ShortcutRow: View {
    let label: String
    @Binding var shortcut: String
    @State private var isRecording = false
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        HStack {
            Text(label)
            Spacer()

            if isRecording {
                Text(NSLocalizedString("Press shortcut", comment: ""))
                    .foregroundColor(.secondary)
                    .frame(minWidth: 100, alignment: .trailing)
                Button(NSLocalizedString("Cancel", comment: "")) { cancelRecording() }
                    .controlSize(.small)
            } else {
                Text(shortcut.isEmpty ? NSLocalizedString("None", comment: "") : shortcut)
                    .foregroundColor(.secondary)
                    .opacity(shortcut.isEmpty ? 0.5 : 1)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 100, alignment: .trailing)
                Button(NSLocalizedString("Record", comment: "")) { startRecording() }
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

class ShortcutRecorder: NSObject, ObservableObject {
    private var monitor: Any?
    private var handler: ((String) -> Void)?

    func start(handler: @escaping (String) -> Void) {
        self.handler = handler
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self != nil else { return event }

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
