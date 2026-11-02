import AppKit
import SwiftUI
import Darwin

@main
struct cterApp: App {
    @StateObject private var tabManager = TabManager()
    @StateObject private var notificationStore = TerminalNotificationStore.shared
    @StateObject private var sidebarState = SidebarState()
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.dark.rawValue
    @AppStorage(SocketControlSettings.appStorageKey) private var socketControlMode = SocketControlSettings.defaultMode.rawValue
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        configureGhosttyEnvironment()
        // Start the terminal controller for programmatic control
        // This runs after TabManager is created via @StateObject
        let defaults = UserDefaults.standard
        if defaults.object(forKey: SocketControlSettings.appStorageKey) == nil,
           let legacy = defaults.object(forKey: SocketControlSettings.legacyEnabledKey) as? Bool {
            defaults.set(legacy ? SocketControlMode.full.rawValue : SocketControlMode.off.rawValue,
                         forKey: SocketControlSettings.appStorageKey)
        }
    }

    private func configureGhosttyEnvironment() {
        let fileManager = FileManager.default
        let ghosttyAppResources = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        let bundledGhosttyURL = Bundle.main.resourceURL?.appendingPathComponent("ghostty")
        var resolvedResourcesDir: String?

        if getenv("GHOSTTY_RESOURCES_DIR") == nil {
            if let bundledGhosttyURL,
               fileManager.fileExists(atPath: bundledGhosttyURL.path),
               fileManager.fileExists(atPath: bundledGhosttyURL.appendingPathComponent("themes").path) {
                resolvedResourcesDir = bundledGhosttyURL.path
            } else if fileManager.fileExists(atPath: ghosttyAppResources) {
                resolvedResourcesDir = ghosttyAppResources
            } else if let bundledGhosttyURL, fileManager.fileExists(atPath: bundledGhosttyURL.path) {
                resolvedResourcesDir = bundledGhosttyURL.path
            }

            if let resolvedResourcesDir {
                setenv("GHOSTTY_RESOURCES_DIR", resolvedResourcesDir, 1)
            }
        }

        if getenv("TERM") == nil {
            setenv("TERM", "xterm-ghostty", 1)
        }

        if getenv("TERM_PROGRAM") == nil {
            setenv("TERM_PROGRAM", "ghostty", 1)
        }

        if let resourcesDir = getenv("GHOSTTY_RESOURCES_DIR").flatMap({ String(cString: $0) }) {
            let resourcesURL = URL(fileURLWithPath: resourcesDir)
            let resourcesParent = resourcesURL.deletingLastPathComponent()
            let dataDir = resourcesParent.path
            let manDir = resourcesParent.appendingPathComponent("man").path
            let bundledTerminfoDir = resourcesURL.appendingPathComponent("terminfo").path
            let siblingTerminfoDir = resourcesParent.appendingPathComponent("terminfo").path

            appendEnvPathIfMissing(
                "XDG_DATA_DIRS",
                path: dataDir,
                defaultValue: "/usr/local/share:/usr/share"
            )
            appendEnvPathIfMissing("MANPATH", path: manDir)

            // Ensure `TERM=xterm-ghostty` works even when launching from Finder
            // (no shell to pre-seed TERMINFO). Prefer a terminfo directory next
            // to the configured ghostty resources, but fall back to the sibling
            // layout used by the Ghostty.app bundle.
            if getenv("TERMINFO") == nil {
                if fileManager.fileExists(atPath: bundledTerminfoDir) {
                    setenv("TERMINFO", bundledTerminfoDir, 1)
                } else if fileManager.fileExists(atPath: siblingTerminfoDir) {
                    setenv("TERMINFO", siblingTerminfoDir, 1)
                }
            }
        }
    }

    private func appendEnvPathIfMissing(_ key: String, path: String, defaultValue: String? = nil) {
        if path.isEmpty { return }
        var current = getenv(key).flatMap { String(cString: $0) } ?? ""
        if current.isEmpty, let defaultValue {
            current = defaultValue
        }
        if current.split(separator: ":").contains(Substring(path)) {
            return
        }
        let updated = current.isEmpty ? path : "\(current):\(path)"
        setenv(key, updated, 1)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tabManager)
                .environmentObject(notificationStore)
                .environmentObject(sidebarState)
                .onAppear {
                    // Start the Unix socket controller for programmatic access
                    updateSocketController()
                    appDelegate.configure(tabManager: tabManager, notificationStore: notificationStore, sidebarState: sidebarState)
                    applyAppearance()
                    if ProcessInfo.processInfo.environment["CTER_UI_TEST_SHOW_SETTINGS"] == "1" {
                        DispatchQueue.main.async {
                            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        }
                    }
                }
                .onChange(of: appearanceMode) { _ in
                    applyAppearance()
                }
                .onChange(of: socketControlMode) { _ in
                    updateSocketController()
                }
        }
        .windowStyle(.hiddenTitleBar)
        Settings {
            SettingsRootView()
        }
        .defaultSize(width: 460, height: 360)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About CTerminal") {
                    showAboutPanel()
                }
                Button("Ghostty Settings…") {
                    GhosttyApp.shared.openConfigurationInTextEdit()
                }
                Button("Reload Configuration") {
                    GhosttyApp.shared.reloadConfiguration()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            // New tab commands
            CommandGroup(replacing: .newItem) {
                Button("New Terminal in Pane") {
                    tabManager.newSurfaceInFocusedPane()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("New Tab") {
                    tabManager.addTab()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Tab") {
                    tabManager.addTab()
                }
                .keyboardShortcut("`", modifiers: [.control, .shift])
            }

            // Close tab
            CommandGroup(after: .newItem) {
                Button("Close Panel") {
                    closePanelOrWindow()
                }
                .keyboardShortcut("w", modifiers: .command)

                Button("Close Tab") {
                    tabManager.closeCurrentTabWithConfirmation()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }

            // Find
            CommandGroup(after: .textEditing) {
                Menu("Find") {
                    Button("Find…") {
                        tabManager.startSearch()
                    }
                    .keyboardShortcut("f", modifiers: .command)

                    Button("Find Next") {
                        tabManager.findNext()
                    }
                    .keyboardShortcut("g", modifiers: .command)

                    Button("Find Previous") {
                        tabManager.findPrevious()
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])

                    Divider()

                    Button("Hide Find Bar") {
                        tabManager.hideFind()
                    }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(!tabManager.isFindVisible)

                    Divider()

                    Button("Use Selection for Find") {
                        tabManager.searchSelection()
                    }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!tabManager.canUseSelectionForFind)
                }

                Button("Render Mermaid Diagram") {
                    MermaidPreviewController.renderFromFocusedSurface(tabManager.selectedSurface)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            }

            // Tab navigation
            CommandGroup(after: .toolbar) {
                Button("Toggle Sidebar") {
                    sidebarState.toggle()
                }
                .keyboardShortcut("b", modifiers: .command)

                Divider()

                Button("Next Tab") {
                    tabManager.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous Tab") {
                    tabManager.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button("Back") {
                    tabManager.navigateBack()
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Forward") {
                    tabManager.navigateForward()
                }
                .keyboardShortcut("]", modifiers: .command)

                Button("Next Terminal in Pane") {
                    tabManager.selectNextSurfaceInPane()
                }
                .keyboardShortcut(.tab, modifiers: .control)

                Button("Previous Terminal in Pane") {
                    tabManager.selectPreviousSurfaceInPane()
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

                Divider()

                // Cmd+1 through Cmd+9 for tab selection
                ForEach(1...9, id: \.self) { number in
                    Button("Tab \(number)") {
                        if number == 9 {
                            tabManager.selectLastTab()
                        } else {
                            tabManager.selectTab(at: number - 1)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }

                Divider()

                Button("Jump to Latest Unread") {
                    AppDelegate.shared?.jumpToLatestUnread()
                }

                Button("Show Notifications") {
                    showNotificationsPopover()
                }
            }
        }
    }

    private func showAboutPanel() {
        AboutWindowController.shared.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyAppearance() {
        guard let mode = AppearanceMode(rawValue: appearanceMode) else { return }
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .auto:
            // Legacy value; treat like system and migrate.
            NSApp.appearance = nil
            appearanceMode = AppearanceMode.system.rawValue
        }
    }

    private func updateSocketController() {
        let mode = SocketControlSettings.effectiveMode(userMode: currentSocketMode)
        if mode != .off {
            TerminalController.shared.start(
                tabManager: tabManager,
                socketPath: SocketControlSettings.socketPath(),
                accessMode: mode
            )
        } else {
            TerminalController.shared.stop()
        }
    }

    private var currentSocketMode: SocketControlMode {
        SocketControlMode(rawValue: socketControlMode) ?? SocketControlSettings.defaultMode
    }

    private func closePanelOrWindow() {
        if let window = NSApp.keyWindow,
           window.identifier?.rawValue == "cter.settings" {
            window.performClose(nil)
            return
        }
        tabManager.closeCurrentPanelWithConfirmation()
    }

    private func showNotificationsPopover() {
        AppDelegate.shared?.toggleNotificationsPopover(animated: false)
    }
}

private final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cter.about")
        window.center()
        window.contentView = NSHostingView(rootView: AboutPanelView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AboutPanelView: View {
    @Environment(\.openURL) private var openURL

    private let githubURL = URL(string: "https://github.com/cuonghx-dev/terminal")

    private var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
    private var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    private var commit: String? {
        if let value = Bundle.main.infoDictionary?["CTERCommit"] as? String, !value.isEmpty {
            return value
        }
        let env = ProcessInfo.processInfo.environment["CTER_COMMIT"] ?? ""
        return env.isEmpty ? nil : env
    }
    private var copyright: String? { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String }

    var body: some View {
        VStack(alignment: .center) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .renderingMode(.original)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)

            VStack(alignment: .center, spacing: 32) {
                VStack(alignment: .center, spacing: 8) {
                    Text("CTerminal")
                        .bold()
                        .font(.title)
                    Text("A Ghostty-based terminal with vertical tabs\nand a notification panel for macOS.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .tint(.secondary)
                        .opacity(0.8)
                }
                .textSelection(.enabled)

                VStack(spacing: 2) {
                    if let version {
                        AboutPropertyRow(label: "Version", text: version)
                    }
                    if let build {
                        AboutPropertyRow(label: "Build", text: build)
                    }
                    let commitText = commit ?? "—"
                    let commitURL = commit.flatMap { hash in
                        URL(string: "https://github.com/cuonghx-dev/terminal/commit/\(hash)")
                    }
                    AboutPropertyRow(label: "Commit", text: commitText, url: commitURL)
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    if let url = githubURL {
                        Button("GitHub") {
                            openURL(url)
                        }
                    }
                }

                if let copy = copyright, !copy.isEmpty {
                    Text(copy)
                        .font(.caption)
                        .textSelection(.enabled)
                        .tint(.secondary)
                        .opacity(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        .frame(minWidth: 280)
        .background(AboutVisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
    }
}

private struct AboutPropertyRow: View {
    private let label: String
    private let text: String
    private let url: URL?

    init(label: String, text: String, url: URL? = nil) {
        self.label = label
        self.text = text
        self.url = url
    }

    @ViewBuilder private var textView: some View {
        Text(text)
            .frame(width: 140, alignment: .leading)
            .padding(.leading, 2)
            .tint(.secondary)
            .opacity(0.8)
            .monospaced()
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .frame(width: 126, alignment: .trailing)
                .padding(.trailing, 2)
            if let url {
                Link(destination: url) {
                    textView
                }
            } else {
                textView
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity)
    }
}

private struct AboutVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let isEmphasized: Bool

    init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        isEmphasized: Bool = false
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.isEmphasized = isEmphasized
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.isEmphasized = isEmphasized
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffect = NSVisualEffectView()
        visualEffect.autoresizingMask = [.width, .height]
        return visualEffect
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case auto

    var id: String { rawValue }

    static var visibleCases: [AppearanceMode] {
        [.system, .light, .dark]
    }

    var displayName: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        case .auto:
            return "Auto"
        }
    }
}

struct SettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.dark.rawValue
    @AppStorage(SocketControlSettings.appStorageKey) private var socketControlMode = SocketControlSettings.defaultMode.rawValue
    @AppStorage("sidebarShowStatusPills") private var sidebarShowStatusPills = true
    @AppStorage("sidebarShowGitBranch") private var sidebarShowGitBranch = true
    @AppStorage("sidebarShowGitBranchIcon") private var sidebarShowGitBranchIcon = false
    @AppStorage("sidebarShowPorts") private var sidebarShowPorts = true
    @AppStorage("sidebarShowLog") private var sidebarShowLog = true
    @AppStorage("sidebarShowProgress") private var sidebarShowProgress = true
    @AppStorage("sidebarShellIntegration") private var sidebarShellIntegration = true
    @AppStorage("sidebarMaxLogEntries") private var sidebarMaxLogEntries = 50
    @AppStorage(SessionStore.restoreSettingKey) private var restoreSessionOnLaunch = true
    @State private var notificationsShortcut = KeyboardShortcutSettings.showNotificationsShortcut()
    @State private var jumpToUnreadShortcut = KeyboardShortcutSettings.jumpToUnreadShortcut()

    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceMode) {
                    ForEach(AppearanceMode.visibleCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section {
                Toggle("Restore tabs on launch", isOn: $restoreSessionOnLaunch)
            } header: {
                Text("Startup")
            } footer: {
                Text("Reopens the previous tabs, splits and pane tabs after a quit or crash. Each terminal starts a new shell in its last directory.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Show status", isOn: $sidebarShowStatusPills)
                Toggle("Show git branch", isOn: $sidebarShowGitBranch)
                Toggle("Show branch icon", isOn: $sidebarShowGitBranchIcon)
                    .disabled(!sidebarShowGitBranch)
                    .padding(.leading, 18)
                Toggle("Show listening ports", isOn: $sidebarShowPorts)
                Toggle("Show latest log entry", isOn: $sidebarShowLog)
                Toggle("Show progress bar", isOn: $sidebarShowProgress)
                Stepper(value: $sidebarMaxLogEntries, in: 10...500, step: 10) {
                    LabeledContent("Max log entries") {
                        Text("\(sidebarMaxLogEntries)").monospacedDigit()
                    }
                }
            } header: {
                Text("Sidebar")
            }

            Section {
                Toggle("Shell integration", isOn: $sidebarShellIntegration)
            } header: {
                Text("Shell Integration")
            } footer: {
                Text("Injects a precmd hook so the sidebar can detect the git branch and listening ports automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                KeyboardShortcutRecorder(label: "Show Notifications", shortcut: $notificationsShortcut)
                    .onChange(of: notificationsShortcut) { newValue in
                        KeyboardShortcutSettings.setShowNotificationsShortcut(newValue)
                    }
                KeyboardShortcutRecorder(label: "Jump to Unread", shortcut: $jumpToUnreadShortcut)
                    .onChange(of: jumpToUnreadShortcut) { newValue in
                        KeyboardShortcutSettings.setJumpToUnreadShortcut(newValue)
                    }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Click a shortcut, then press the new key combination.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Picker("Socket control", selection: $socketControlMode) {
                    ForEach(SocketControlMode.allCases) { mode in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                            Text(mode.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("AutomationSocketModePicker")
            } header: {
                Text("Automation")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        "Exposes a local Unix socket for programmatic control. This can be a security risk on shared machines.",
                        systemImage: "exclamationmark.triangle"
                    )
                    Text("Environment overrides: CTER_SOCKET_ENABLE, CTER_SOCKET_MODE, CTER_SOCKET_PATH.")
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset All Settings…", role: .destructive) {
                        showResetConfirmation = true
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 360)
        .confirmationDialog(
            "Reset all settings?",
            isPresented: $showResetConfirmation
        ) {
            Button("Reset", role: .destructive) { resetAllSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Theme, sidebar, shortcut and automation settings return to their defaults. This cannot be undone.")
        }
    }

    private func resetAllSettings() {
        appearanceMode = AppearanceMode.dark.rawValue
        socketControlMode = SocketControlSettings.defaultMode.rawValue
        sidebarShowStatusPills = true
        sidebarShowGitBranch = true
        sidebarShowGitBranchIcon = false
        sidebarShowPorts = true
        sidebarShowLog = true
        sidebarShowProgress = true
        sidebarShellIntegration = true
        sidebarMaxLogEntries = 50
        restoreSessionOnLaunch = true
        KeyboardShortcutSettings.resetAll()
        notificationsShortcut = KeyboardShortcutSettings.showNotificationsDefault
        jumpToUnreadShortcut = KeyboardShortcutSettings.jumpToUnreadDefault
    }
}

private struct SettingsRootView: View {
    var body: some View {
        SettingsView()
            .background(WindowAccessor { window in
                configureSettingsWindow(window)
            })
    }

    private func configureSettingsWindow(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier("cter.settings")
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        window.styleMask.insert(.resizable)
        window.contentMinSize = NSSize(width: 460, height: 360)
        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: NSToolbar.Identifier("cter.settings.toolbar"))
            toolbar.displayMode = .iconOnly
            toolbar.sizeMode = .regular
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
        }

        let accessories = window.titlebarAccessoryViewControllers
        for index in accessories.indices.reversed() {
            guard let identifier = accessories[index].view.identifier?.rawValue else { continue }
            guard identifier.hasPrefix("cter.") else { continue }
            window.removeTitlebarAccessoryViewController(at: index)
        }
        AppDelegate.shared?.applyWindowDecorations(to: window)
    }
}
