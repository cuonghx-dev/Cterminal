import AppKit
import CoreServices
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate?

    weak var tabManager: TabManager?
    weak var notificationStore: TerminalNotificationStore?
    weak var sidebarState: SidebarState?
    private var workspaceObserver: NSObjectProtocol?
    private var shortcutMonitor: Any?
    private let titlebarAccessoryController = TitlebarAccessoryController()
    private let windowDecorationsController = WindowDecorationsController()
#if DEBUG
    private var didSetupJumpUnreadUITest = false
    private var jumpUnreadFocusExpectation: (tabId: UUID, surfaceId: UUID)?
#endif

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerLaunchServicesBundle()
        enforceSingleInstance()
        NSWindow.allowsAutomaticWindowTabbing = false
        disableNativeTabbingShortcut()
        ensureApplicationIcon()
        observeDuplicateLaunches()
        configureUserNotifications()
        titlebarAccessoryController.start()
        windowDecorationsController.start()
        installShortcutMonitor()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let tabManager, let notificationStore else { return }
        guard let tabId = tabManager.selectedTabId else { return }
        let surfaceId = tabManager.focusedSurfaceId(for: tabId)
        guard notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) else { return }

        if let surfaceId,
           let tab = tabManager.tabs.first(where: { $0.id == tabId }) {
            tab.triggerNotificationFocusFlash(surfaceId: surfaceId, requiresSplit: false, shouldFocus: false)
        }
        notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId)
    }

    func applicationWillTerminate(_ notification: Notification) {
        tabManager?.saveSession()
        notificationStore?.clearAll()
    }

    func configure(tabManager: TabManager, notificationStore: TerminalNotificationStore, sidebarState: SidebarState) {
        self.tabManager = tabManager
        self.notificationStore = notificationStore
        self.sidebarState = sidebarState
#if DEBUG
        setupJumpUnreadUITestIfNeeded()
#endif
    }

#if DEBUG
    private func setupJumpUnreadUITestIfNeeded() {
        guard !didSetupJumpUnreadUITest else { return }
        didSetupJumpUnreadUITest = true
        let env = ProcessInfo.processInfo.environment
        guard env["CTER_UI_TEST_JUMP_UNREAD_SETUP"] == "1" else { return }
        guard let tabManager, let notificationStore else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            let initialIndex = tabManager.tabs.firstIndex(where: { $0.id == tabManager.selectedTabId }) ?? 0
            let tab = tabManager.addTab()
            guard let initialSurfaceId = tab.focusedSurfaceId else { return }

            _ = tabManager.newSplit(tabId: tab.id, surfaceId: initialSurfaceId, direction: .right)
            guard let targetSurfaceId = tab.focusedSurfaceId else { return }
            let otherSurfaceId = tab.allSurfaces.first(where: { $0.id != targetSurfaceId })?.id
            if let otherSurfaceId {
                tab.focusedSurfaceId = otherSurfaceId
            }

            notificationStore.addNotification(
                tabId: tab.id,
                surfaceId: targetSurfaceId,
                title: "JumpToUnread",
                subtitle: "",
                body: ""
            )

            self.writeJumpUnreadTestData([
                "expectedTabId": tab.id.uuidString,
                "expectedSurfaceId": targetSurfaceId.uuidString
            ])

            tabManager.selectTab(at: initialIndex)
        }
    }

    func recordJumpToUnreadFocus(tabId: UUID, surfaceId: UUID) {
        writeJumpUnreadTestData([
            "focusedTabId": tabId.uuidString,
            "focusedSurfaceId": surfaceId.uuidString
        ])
    }

    func armJumpUnreadFocusRecord(tabId: UUID, surfaceId: UUID) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CTER_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
        jumpUnreadFocusExpectation = (tabId: tabId, surfaceId: surfaceId)
    }

    func recordJumpUnreadFocusIfExpected(tabId: UUID, surfaceId: UUID) {
        guard let expectation = jumpUnreadFocusExpectation else { return }
        guard expectation.tabId == tabId && expectation.surfaceId == surfaceId else { return }
        jumpUnreadFocusExpectation = nil
        recordJumpToUnreadFocus(tabId: tabId, surfaceId: surfaceId)
    }

    private func writeJumpUnreadTestData(_ updates: [String: String]) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CTER_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
        var payload = loadJumpUnreadTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadJumpUnreadTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
#endif

    func attachTitlebarAccessory(to window: NSWindow) {
        titlebarAccessoryController.start()
        titlebarAccessoryController.attach(to: window)
    }

    func applyWindowDecorations(to window: NSWindow) {
        windowDecorationsController.apply(to: window)
    }

    func toggleNotificationsPopover(animated: Bool = true) {
        titlebarAccessoryController.toggleNotificationsPopover(animated: animated)
    }

    func jumpToLatestUnread() {
        guard let notificationStore, let tabManager else { return }
        guard let notification = notificationStore.notifications.first(where: { !$0.isRead }) else { return }
        tabManager.focusTabFromNotification(notification.tabId, surfaceId: notification.surfaceId)
    }

    private func installShortcutMonitor() {
        // Local monitor only receives events when app is active (not global)
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleCustomShortcut(event: event) {
                return nil // Consume the event
            }
            self.repairTerminalKeyRoutingIfNeeded(event: event)
            return event // Pass through
        }
    }

    /// Split close and pane-tab switches can leave the first responder on a view that
    /// was removed or hidden (or on the window itself), so typing goes nowhere and the
    /// terminal looks frozen. Before a plain key reaches AppKit, move focus back to
    /// the focused terminal when the current responder can't route keys.
    private func repairTerminalKeyRoutingIfNeeded(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command) else { return }
        guard let window = event.window ?? NSApp.keyWindow,
              window.attachedSheet == nil,
              let tab = tabManager?.selectedTab,
              let surface = tab.focusedSurface,
              surface.hostedView.window === window else { return }

        if let view = window.firstResponder as? NSView,
           view.window === window,
           !view.isHiddenOrHasHiddenAncestor,
           view.superview != nil || view === window.contentView {
            return
        }

        surface.hostedView.ensureFocus(for: tab.id, surfaceId: surface.id)
    }

    private func handleCustomShortcut(event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // When the terminal has active IME composition (e.g. Vietnamese, Korean, Japanese,
        // Chinese input), don't intercept key events — let them flow through to the input method.
        if let ghosttyView = NSApp.keyWindow?.firstResponder as? GhosttyNSView,
           ghosttyView.hasMarkedText() {
            return false
        }

        // Check Show Notifications shortcut
        let notifShortcut = KeyboardShortcutSettings.showNotificationsShortcut()
        if chars == notifShortcut.key && flags == notifShortcut.modifierFlags {
            toggleNotificationsPopover(animated: false)
            return true
        }

        // Check Jump to Unread shortcut
        let unreadShortcut = KeyboardShortcutSettings.jumpToUnreadShortcut()
        if chars == unreadShortcut.key && flags == unreadShortcut.modifierFlags {
            jumpToLatestUnread()
            return true
        }

        return false
    }


    private func configureUserNotifications() {
        let actions = [
            UNNotificationAction(
                identifier: TerminalNotificationStore.actionShowIdentifier,
                title: "Show"
            )
        ]

        let category = UNNotificationCategory(
            identifier: TerminalNotificationStore.categoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = self
    }

    private func disableNativeTabbingShortcut() {
        guard let menu = NSApp.mainMenu else { return }
        disableMenuItemShortcut(in: menu, action: #selector(NSWindow.toggleTabBar(_:)))
    }

    private func disableMenuItemShortcut(in menu: NSMenu, action: Selector) {
        for item in menu.items {
            if item.action == action {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                item.isEnabled = false
            }
            if let submenu = item.submenu {
                disableMenuItemShortcut(in: submenu, action: action)
            }
        }
    }

    private func ensureApplicationIcon() {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    private func registerLaunchServicesBundle() {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let registerStatus = LSRegisterURL(bundleURL as CFURL, true)
        if registerStatus != noErr {
            NSLog("LaunchServices registration failed (status: \(registerStatus)) for \(bundleURL.path)")
        }
    }

    private func enforceSingleInstance() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let currentPid = ProcessInfo.processInfo.processIdentifier
        let currentURL = Bundle.main.bundleURL.standardizedFileURL

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
            guard app.processIdentifier != currentPid else { continue }
            if let url = app.bundleURL?.standardizedFileURL, url == currentURL { continue }
            app.terminate()
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
        }
    }

    private func observeDuplicateLaunches() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        let currentPid = ProcessInfo.processInfo.processIdentifier
        let currentURL = Bundle.main.bundleURL.standardizedFileURL

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard self != nil else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.bundleIdentifier == bundleId, app.processIdentifier != currentPid else { return }
            if let url = app.bundleURL?.standardizedFileURL, url == currentURL { return }

            app.terminate()
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleNotificationResponse(response)
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    private func handleNotificationResponse(_ response: UNNotificationResponse) {
        guard let tabIdString = response.notification.request.content.userInfo["tabId"] as? String,
              let tabId = UUID(uuidString: tabIdString) else {
            return
        }
        let surfaceId: UUID? = {
            guard let surfaceIdString = response.notification.request.content.userInfo["surfaceId"] as? String else {
                return nil
            }
            return UUID(uuidString: surfaceIdString)
        }()

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, TerminalNotificationStore.actionShowIdentifier:
            DispatchQueue.main.async {
                self.tabManager?.focusTabFromNotification(tabId, surfaceId: surfaceId)
                self.markReadIfFocused(response: response, tabId: tabId, surfaceId: surfaceId)
            }
        case UNNotificationDismissActionIdentifier:
            DispatchQueue.main.async {
                if let notificationId = UUID(uuidString: response.notification.request.identifier) {
                    self.notificationStore?.markRead(id: notificationId)
                } else if let notificationIdString = response.notification.request.content.userInfo["notificationId"] as? String,
                          let notificationId = UUID(uuidString: notificationIdString) {
                    self.notificationStore?.markRead(id: notificationId)
                }
            }
        default:
            break
        }
    }

    private func markReadIfFocused(response: UNNotificationResponse, tabId: UUID, surfaceId: UUID?) {
        let notificationId: UUID? = {
            if let id = UUID(uuidString: response.notification.request.identifier) {
                return id
            }
            if let idString = response.notification.request.content.userInfo["notificationId"] as? String,
               let id = UUID(uuidString: idString) {
                return id
            }
            return nil
        }()

        guard let notificationId else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let tabManager = self.tabManager else { return }
            guard tabManager.selectedTabId == tabId else { return }
            if let surfaceId {
                guard tabManager.focusedSurfaceId(for: tabId) == surfaceId else { return }
            }
            self.notificationStore?.markRead(id: notificationId)
        }
    }

}
