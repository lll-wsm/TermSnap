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
                ShortcutRow(label: NSLocalizedString("Capture", comment: ""), shortcut: $shortcutCapture) { keyString, keyCode, modifiers in
                    AppSettings.shortcutCapture = keyString
                    AppSettings.shortcutCaptureKeyCode = keyCode
                    AppSettings.shortcutCaptureModifiers = modifiers
                    
                    // Trigger re-registration
                    NotificationCenter.default.post(name: Notification.Name("ShortcutChanged"), object: nil)
                }
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
    @StateObject private var templateManager = TemplateManager.shared
    @State private var enabledTemplates = AppSettings.enabledTemplates
    @State private var showTerminalMenu = AppSettings.showTerminalMenu
    @State private var showCreateFileMenu = AppSettings.showCreateFileMenu
    @State private var menuLayout = AppSettings.menuLayout
    @State private var showTemplateIcons = AppSettings.showTemplateIcons
    @State private var showFinderIcon = AppSettings.showFinderIcon

    var body: some View {
        Form {
            Section {
                Toggle(NSLocalizedString("Show Icon in Context Menu", comment: ""), isOn: $showFinderIcon)
                
                Picker(NSLocalizedString("Menu Layout", comment: ""), selection: $menuLayout) {
                    Text(NSLocalizedString("Flat", comment: "")).tag("flat")
                    Text(NSLocalizedString("Nested", comment: "")).tag("nested")
                }
                .pickerStyle(.segmented)
                
                Toggle(NSLocalizedString("Show Icons for Templates", comment: ""), isOn: $showTemplateIcons)
            } header: {
                Label(NSLocalizedString("Finder Integration", comment: ""), systemImage: "macwindow")
            }
            
            Section {
                Toggle(NSLocalizedString("Open Terminal Here", comment: ""), isOn: $showTerminalMenu)
                Toggle(NSLocalizedString("Create New File (Submenu)", comment: ""), isOn: $showCreateFileMenu)
            } header: {
                Label(NSLocalizedString("Menu Items", comment: ""), systemImage: "list.bullet")
            }
            
            if showCreateFileMenu {
                Section {
                    Button(NSLocalizedString("Open Templates Folder", comment: "")) {
                        templateManager.openTemplatesFolder()
                    }
                    
                    List {
                        ForEach(templateManager.availableTemplates, id: \.self) { template in
                            HStack {
                                Image(nsImage: templateManager.getIcon(for: template))
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                Text(template.lastPathComponent)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { enabledTemplates.contains(template.lastPathComponent) },
                                    set: { isOn in
                                        if isOn {
                                            if !enabledTemplates.contains(template.lastPathComponent) {
                                                enabledTemplates.append(template.lastPathComponent)
                                            }
                                        } else {
                                            enabledTemplates.removeAll { $0 == template.lastPathComponent }
                                        }
                                    }
                                )).labelsHidden()
                            }
                        }
                    }
                    .frame(minHeight: 150)
                } header: {
                    Text(NSLocalizedString("Enabled Templates", comment: ""))
                } footer: {
                    Text(NSLocalizedString("Any file in the Templates folder will appear here. Toggle to show/hide in the Finder menu.", comment: ""))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("Context Menu", comment: ""))
        .onAppear { templateManager.refreshTemplates() }
        .onChange(of: enabledTemplates) { _, newValue in AppSettings.enabledTemplates = newValue }
        .onChange(of: showTerminalMenu) { _, newValue in AppSettings.showTerminalMenu = newValue }
        .onChange(of: showCreateFileMenu) { _, newValue in AppSettings.showCreateFileMenu = newValue }
        .onChange(of: menuLayout) { _, newValue in AppSettings.menuLayout = newValue }
        .onChange(of: showTemplateIcons) { _, newValue in AppSettings.showTemplateIcons = newValue }
        .onChange(of: showFinderIcon) { _, newValue in AppSettings.showFinderIcon = newValue }
    }
}

// MARK: - Shortcut Row

struct ShortcutRow: View {
    let label: String
    @Binding var shortcut: String
    var onRecord: ((String, Int, UInt) -> Void)? = nil
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
        recorder.start { keyString, keyCode, modifiers in
            shortcut = keyString
            onRecord?(keyString, keyCode, modifiers)
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
    private var handler: ((String, Int, UInt) -> Void)?

    func start(handler: @escaping (String, Int, UInt) -> Void) {
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

            handler(parts.joined(), Int(event.keyCode), modifiers.rawValue)
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
