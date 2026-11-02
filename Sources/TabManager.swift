import AppKit
import SwiftUI
import Foundation

struct SidebarStatusEntry: Identifiable {
    let id = UUID()
    let key: String
    var value: String
    var icon: String?
    var color: String?
    var timestamp: Date
}

enum SidebarLogLevel: String {
    case info, progress, success, warning, error
}

struct SidebarLogEntry: Identifiable {
    let id = UUID()
    let message: String
    let level: SidebarLogLevel
    let source: String?
    let timestamp: Date
}

/// A leaf of a tab's split tree. Each pane holds one or more terminal surfaces shown as
/// tabs in the pane's tab bar; only the selected surface is visible.
final class TerminalPane: Identifiable, ObservableObject {
    let id = UUID()
    @Published private(set) var surfaces: [TerminalSurface]
    @Published var selectedSurfaceId: UUID

    init(surface: TerminalSurface) {
        self.surfaces = [surface]
        self.selectedSurfaceId = surface.id
    }

    /// Builds a pane with several surfaces (session restore). `surfaces` must not be empty.
    init(surfaces: [TerminalSurface], selectedIndex: Int) {
        precondition(!surfaces.isEmpty, "TerminalPane needs at least one surface")
        self.surfaces = surfaces
        self.selectedSurfaceId = surfaces[max(0, min(selectedIndex, surfaces.count - 1))].id
    }

    var selectedSurface: TerminalSurface? {
        surfaces.first(where: { $0.id == selectedSurfaceId }) ?? surfaces.first
    }

    func contains(surfaceId: UUID) -> Bool {
        surfaces.contains(where: { $0.id == surfaceId })
    }

    /// Inserts a surface right after the selected one and selects it.
    func insert(_ surface: TerminalSurface) {
        let index = surfaces.firstIndex(where: { $0.id == selectedSurfaceId }).map { $0 + 1 } ?? surfaces.count
        surfaces.insert(surface, at: index)
        selectedSurfaceId = surface.id
    }

    /// Removes a surface. If it was selected, selects its right neighbor (or the left one at the end).
    func remove(surfaceId: UUID) {
        guard let index = surfaces.firstIndex(where: { $0.id == surfaceId }) else { return }
        surfaces.remove(at: index)
        guard selectedSurfaceId == surfaceId, !surfaces.isEmpty else { return }
        selectedSurfaceId = surfaces[min(index, surfaces.count - 1)].id
    }

    /// Inserts a surface at `index` (clamped), or after the selected one when nil, and selects it.
    func insert(_ surface: TerminalSurface, at index: Int?) {
        guard let index else {
            insert(surface)
            return
        }
        surfaces.insert(surface, at: max(0, min(index, surfaces.count)))
        selectedSurfaceId = surface.id
    }

    /// Moves a surface so it lands before the surface currently at `index`
    /// (`surfaces.count` moves it to the end).
    func move(surfaceId: UUID, toInsertionIndex index: Int) {
        guard let from = surfaces.firstIndex(where: { $0.id == surfaceId }) else { return }
        let destination = from < index ? index - 1 : index
        guard destination != from else { return }
        move(surfaceId: surfaceId, to: destination)
    }

    func move(surfaceId: UUID, to destination: Int) {
        guard let index = surfaces.firstIndex(where: { $0.id == surfaceId }) else { return }
        let surface = surfaces.remove(at: index)
        surfaces.insert(surface, at: max(0, min(destination, surfaces.count)))
    }

    func surfaceId(offsetFrom surfaceId: UUID, by offset: Int) -> UUID? {
        guard surfaces.count > 1,
              let index = surfaces.firstIndex(where: { $0.id == surfaceId }) else { return nil }
        let count = surfaces.count
        return surfaces[((index + offset) % count + count) % count].id
    }
}

class Tab: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var customTitle: String?
    @Published var isPinned: Bool = false
    @Published var currentDirectory: String
    @Published var splitTree: SplitTree<TerminalPane>
    @Published var focusedSurfaceId: UUID? {
        didSet {
            guard let focusedSurfaceId else { return }
            if let pane = pane(containing: focusedSurfaceId), pane.selectedSurfaceId != focusedSurfaceId {
                pane.selectedSurfaceId = focusedSurfaceId
            }
            AppDelegate.shared?.tabManager?.rememberFocusedSurface(tabId: id, surfaceId: focusedSurfaceId)
            AppDelegate.shared?.tabManager?.focusedSurfaceTitleDidChange(tabId: id)
            NotificationCenter.default.post(
                name: .ghosttyDidFocusSurface,
                object: nil,
                userInfo: [
                    GhosttyNotificationKey.tabId: id,
                    GhosttyNotificationKey.surfaceId: focusedSurfaceId
                ]
            )
        }
    }
    @Published var surfaceDirectories: [UUID: String] = [:]
    @Published var surfaceTitles: [UUID: String] = [:]
    var splitViewSize: CGSize = .zero

    // Sidebar metadata
    @Published var statusEntries: [String: SidebarStatusEntry] = [:]
    @Published var logEntries: [SidebarLogEntry] = []
    @Published var progress: (value: Double, label: String?)? = nil
    @Published var gitBranch: (branch: String, isDirty: Bool)? = nil
    // Per-surface ports reported by shell integration. `listeningPorts` is the union for display.
    @Published var surfaceListeningPorts: [UUID: [Int]] = [:]
    @Published var listeningPorts: [Int] = []

    static let maxLogEntries = 50

    private var processTitle: String

    init(title: String = "Terminal", workingDirectory: String? = nil) {
        self.id = UUID()
        self.processTitle = title
        self.title = title
        self.customTitle = nil
        let trimmedWorkingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasWorkingDirectory = !trimmedWorkingDirectory.isEmpty
        self.currentDirectory = hasWorkingDirectory
            ? trimmedWorkingDirectory
            : FileManager.default.homeDirectoryForCurrentUser.path
        let surface = TerminalSurface(
            tabId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: nil,
            workingDirectory: hasWorkingDirectory ? trimmedWorkingDirectory : nil
        )
        self.splitTree = SplitTree(view: TerminalPane(surface: surface))
        self.focusedSurfaceId = surface.id
    }

    /// Builds a tab around a surface dragged out of another tab.
    init(adopting surface: TerminalSurface, metadata: SurfaceMetadata) {
        let id = UUID()
        self.id = id
        let title = metadata.title ?? "Terminal"
        self.processTitle = title
        self.title = title
        self.customTitle = nil
        self.currentDirectory = metadata.directory ?? FileManager.default.homeDirectoryForCurrentUser.path
        surface.reassign(toTab: id)
        self.splitTree = SplitTree(view: TerminalPane(surface: surface))
        self.focusedSurfaceId = surface.id
        applyMetadata(metadata, for: surface.id)
    }

    /// Rebuilds a tab from a saved session: same split layout and pane tabs, each running a
    /// fresh shell in its saved directory (or the home folder if it no longer exists).
    init(restoring snapshot: SessionSnapshot.TabSnapshot) {
        let id = UUID()
        self.id = id
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tabDirectory = SessionSnapshot.existingDirectory(snapshot.currentDirectory)
        self.currentDirectory = tabDirectory ?? home

        var directories: [UUID: String] = [:]
        var titles: [UUID: String] = [:]
        var orderedSurfaceIds: [UUID] = []

        func makeNode(_ node: SessionSnapshot.NodeSnapshot) -> SplitTree<TerminalPane>.Node {
            switch node {
            case .pane(let pane):
                let saved = pane.surfaces.isEmpty ? [SessionSnapshot.SurfaceSnapshot()] : pane.surfaces
                let surfaces = saved.map { savedSurface -> TerminalSurface in
                    let directory = SessionSnapshot.existingDirectory(savedSurface.directory) ?? tabDirectory
                    let surface = TerminalSurface(
                        tabId: id,
                        context: GHOSTTY_SURFACE_CONTEXT_TAB,
                        configTemplate: nil,
                        workingDirectory: directory
                    )
                    if let directory { directories[surface.id] = directory }
                    if let title = savedSurface.title, !title.isEmpty { titles[surface.id] = title }
                    orderedSurfaceIds.append(surface.id)
                    return surface
                }
                return .leaf(view: TerminalPane(surfaces: surfaces, selectedIndex: pane.selectedIndex))
            case .split(let split):
                return .split(.init(
                    direction: split.direction == .horizontal ? .horizontal : .vertical,
                    ratio: max(0.1, min(0.9, split.ratio)),
                    left: makeNode(split.left),
                    right: makeNode(split.right)
                ))
            }
        }

        let root = makeNode(snapshot.layout)
        self.splitTree = SplitTree(root: root, zoomed: nil)
        self.surfaceDirectories = directories
        self.surfaceTitles = titles
        self.isPinned = snapshot.isPinned

        let focusedId = snapshot.focusedSurfaceIndex
            .flatMap { orderedSurfaceIds.indices.contains($0) ? orderedSurfaceIds[$0] : nil }
            ?? root.leftmostLeaf().selectedSurface?.id
        let title = focusedId.flatMap { titles[$0] } ?? "Terminal"
        self.processTitle = title
        self.title = title
        self.customTitle = nil
        self.focusedSurfaceId = focusedId
        if let customTitle = snapshot.customTitle {
            setCustomTitle(customTitle)
        }
    }

    var panes: [TerminalPane] {
        splitTree.root?.leaves() ?? []
    }

    var focusedPane: TerminalPane? {
        focusedSurfaceId.flatMap(pane(containing:))
    }

    func pane(id paneId: UUID) -> TerminalPane? {
        panes.first(where: { $0.id == paneId })
    }

    /// Every terminal surface in this tab, in split order then pane-tab order.
    var allSurfaces: [TerminalSurface] {
        panes.flatMap(\.surfaces)
    }

    func pane(containing surfaceId: UUID) -> TerminalPane? {
        panes.first(where: { $0.contains(surfaceId: surfaceId) })
    }

    var focusedSurface: TerminalSurface? {
        guard let focusedSurfaceId else { return nil }
        return surface(for: focusedSurfaceId)
    }

    var hasCustomTitle: Bool {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    func applyProcessTitle(_ title: String) {
        processTitle = title
        guard customTitle == nil else { return }
        self.title = title
    }

    func setCustomTitle(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            customTitle = nil
            self.title = processTitle
        } else {
            customTitle = trimmed
            self.title = trimmed
        }
    }

    func surface(for id: UUID) -> TerminalSurface? {
        allSurfaces.first(where: { $0.id == id })
    }

    /// Focuses a surface and moves keyboard focus to it (e.g. when a pane tab is clicked).
    func selectSurface(_ surfaceId: UUID) {
        guard let surface = surface(for: surfaceId) else { return }
        let previous = focusedSurface
        focusSurface(surfaceId)
        guard previous !== surface else { return }
        DispatchQueue.main.async {
            surface.hostedView.moveFocus(from: previous?.hostedView)
        }
    }

    func focusSurface(_ id: UUID) {
        let wasFocused = focusedSurfaceId == id
        focusedSurfaceId = id
        let isSelectedTab = AppDelegate.shared?.tabManager?.selectedTabId == self.id
        if isSelectedTab {
            focusedSurface?.applyWindowBackgroundIfActive()
        }
        let isAppActive = AppFocusState.isAppActive()
        guard isSelectedTab && isAppActive else { return }
        guard let notificationStore = AppDelegate.shared?.notificationStore else { return }
        if notificationStore.hasUnreadNotification(forTabId: self.id, surfaceId: id) {
            triggerNotificationFocusFlash(surfaceId: id, requiresSplit: false, shouldFocus: false)
            notificationStore.markRead(forTabId: self.id, surfaceId: id)
            return
        }
        if !wasFocused {
            notificationStore.markRead(forTabId: self.id, surfaceId: id)
        }
    }

    func updateSurfaceDirectory(surfaceId: UUID, directory: String) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if surfaceDirectories[surfaceId] != trimmed {
            surfaceDirectories[surfaceId] = trimmed
        }
        currentDirectory = trimmed
    }

    func recomputeListeningPorts() {
        let merged = surfaceListeningPorts.values.reduce(into: Set<Int>()) { acc, ports in
            for port in ports {
                acc.insert(port)
            }
        }
        let sorted = merged.sorted()
        if listeningPorts != sorted {
            listeningPorts = sorted
        }
    }

    func pruneSurfaceMetadata(validSurfaceIds: Set<UUID>? = nil) {
        let validIds = validSurfaceIds ?? Set(allSurfaces.map { $0.id })

        if surfaceDirectories.keys.contains(where: { !validIds.contains($0) }) {
            surfaceDirectories = surfaceDirectories.filter { validIds.contains($0.key) }
        }
        if surfaceTitles.keys.contains(where: { !validIds.contains($0) }) {
            surfaceTitles = surfaceTitles.filter { validIds.contains($0.key) }
        }
        if surfaceListeningPorts.keys.contains(where: { !validIds.contains($0) }) {
            surfaceListeningPorts = surfaceListeningPorts.filter { validIds.contains($0.key) }
        }

        recomputeListeningPorts()
    }

    func triggerNotificationFocusFlash(
        surfaceId: UUID,
        requiresSplit: Bool = false,
        shouldFocus: Bool = true
    ) {
        triggerPanelFlash(surfaceId: surfaceId, requiresSplit: requiresSplit, shouldFocus: shouldFocus)
    }

    func triggerDebugFlash(surfaceId: UUID) {
        triggerPanelFlash(surfaceId: surfaceId, requiresSplit: false, shouldFocus: true)
    }

    private func triggerPanelFlash(surfaceId: UUID, requiresSplit: Bool, shouldFocus: Bool) {
        guard let surface = surface(for: surfaceId) else { return }
        if shouldFocus {
            if focusedSurfaceId != surfaceId {
                focusSurface(surfaceId)
            }
            surface.hostedView.ensureFocus(for: self.id, surfaceId: surfaceId)
        }
        if requiresSplit && !splitTree.isSplit {
            return
        }
        triggerFlashWhenReady(surface: surface)
    }

    private func triggerFlashWhenReady(surface: TerminalSurface, attempts: Int = 0) {
        let maxAttempts = 6
        let view = surface.hostedView
        if view.window != nil {
            view.layoutSubtreeIfNeeded()
        }
        let hasBounds = view.bounds.width > 0 && view.bounds.height > 0
        if view.window != nil && hasBounds {
            view.triggerFlash()
            return
        }
        guard attempts < maxAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.triggerFlashWhenReady(surface: surface, attempts: attempts + 1)
        }
    }

    func updateSplitViewSize(_ size: CGSize) {
        guard splitViewSize != size else { return }
        splitViewSize = size
    }

    func updateSplitRatio(node: SplitTree<TerminalPane>.Node, ratio: Double) {
        do {
            splitTree = try splitTree.replacing(node: node, with: node.resizing(to: ratio))
        } catch {
            return
        }
    }

    func equalizeSplits() {
        splitTree = splitTree.equalized()
    }

    private func makeSurface(inheritingFrom surfaceId: UUID, context: ghostty_surface_context_e) -> TerminalSurface {
        let inheritedConfig: ghostty_surface_config_s? = if let existing = surface(for: surfaceId)?.surface {
            ghostty_surface_inherited_config(existing, context)
        } else {
            nil
        }
        return TerminalSurface(
            tabId: id,
            context: context,
            configTemplate: inheritedConfig
        )
    }

    func newSplit(from surfaceId: UUID, direction: SplitTree<TerminalPane>.NewDirection) -> TerminalSurface? {
        guard let targetPane = pane(containing: surfaceId) else { return nil }
        let newSurface = makeSurface(inheritingFrom: surfaceId, context: GHOSTTY_SURFACE_CONTEXT_SPLIT)

        do {
            splitTree = try splitTree.inserting(view: TerminalPane(surface: newSurface), at: targetPane, direction: direction)
            focusedSurfaceId = newSurface.id
            return newSurface
        } catch {
            return nil
        }
    }

    /// Opens a new terminal as a tab in the pane that contains `surfaceId`.
    func newSurface(inPaneOf surfaceId: UUID) -> TerminalSurface? {
        guard let targetPane = pane(containing: surfaceId) else { return nil }
        let newSurface = makeSurface(inheritingFrom: surfaceId, context: GHOSTTY_SURFACE_CONTEXT_TAB)
        targetPane.insert(newSurface)
        focusedSurfaceId = newSurface.id
        return newSurface
    }

    /// Selects the pane tab `offset` positions away from `surfaceId`, wrapping around.
    func cycleSurface(inPaneOf surfaceId: UUID, by offset: Int) -> Bool {
        guard let targetId = pane(containing: surfaceId)?.surfaceId(offsetFrom: surfaceId, by: offset) else {
            return false
        }
        selectSurface(targetId)
        return true
    }

    func moveFocus(from surfaceId: UUID, direction: SplitTree<TerminalPane>.FocusDirection) -> Bool {
        guard let root = splitTree.root,
              let pane = pane(containing: surfaceId),
              let targetNode = root.find(id: pane.id),
              let nextSurface = splitTree.focusTarget(for: direction, from: targetNode)?.selectedSurface else {
            return false
        }

        focusedSurfaceId = nextSurface.id
        return true
    }

    func resizeSplit(from surfaceId: UUID, direction: SplitTree<TerminalPane>.Spatial.Direction, amount: UInt16) -> Bool {
        guard let root = splitTree.root,
              let pane = pane(containing: surfaceId),
              let targetNode = root.find(id: pane.id),
              splitViewSize.width > 0,
              splitViewSize.height > 0 else {
            return false
        }

        do {
            splitTree = try splitTree.resizing(
                node: targetNode,
                by: amount,
                in: direction,
                with: CGRect(origin: .zero, size: splitViewSize)
            )
            return true
        } catch {
            return false
        }
    }

    func toggleZoom(on surfaceId: UUID) -> Bool {
        guard let root = splitTree.root,
              let pane = pane(containing: surfaceId),
              let targetNode = root.find(id: pane.id) else {
            return false
        }

        guard splitTree.isSplit else { return false }

        if splitTree.zoomed == targetNode {
            splitTree = SplitTree(root: splitTree.root, zoomed: nil)
        } else {
            splitTree = SplitTree(root: splitTree.root, zoomed: targetNode)
        }
        return true
    }

    private func findNextFocusTargetAfterClosing(
        node: SplitTree<TerminalPane>.Node
    ) -> TerminalPane? {
        guard let root = splitTree.root else { return nil }

        if root.leftmostLeaf() === node.leftmostLeaf() {
            return splitTree.focusTarget(for: .next, from: node)
        }

        return splitTree.focusTarget(for: .previous, from: node)
    }

    /// Per-surface sidebar metadata that travels with a surface moved to another tab.
    struct SurfaceMetadata {
        var title: String?
        var directory: String?
        var ports: [Int]?
    }

    func surfaceMetadata(for surfaceId: UUID) -> SurfaceMetadata {
        SurfaceMetadata(
            title: surfaceTitles[surfaceId],
            directory: surfaceDirectories[surfaceId],
            ports: surfaceListeningPorts[surfaceId]
        )
    }

    private func applyMetadata(_ metadata: SurfaceMetadata, for surfaceId: UUID) {
        if let title = metadata.title { surfaceTitles[surfaceId] = title }
        if let directory = metadata.directory { surfaceDirectories[surfaceId] = directory }
        if let ports = metadata.ports {
            surfaceListeningPorts[surfaceId] = ports
            recomputeListeningPorts()
        }
    }

    /// Takes a surface out of this tab's layout without terminating it, so it can be placed
    /// elsewhere. The tab's split tree is empty afterwards if it was the last surface.
    func detachSurface(_ surfaceId: UUID) -> TerminalSurface? {
        guard let surface = surface(for: surfaceId), closeSurface(surfaceId) else { return nil }
        return surface
    }

    /// Places a detached surface as a tab of `paneId` (the focused pane when nil).
    func adoptSurface(
        _ surface: TerminalSurface,
        metadata: SurfaceMetadata,
        intoPane paneId: UUID?,
        at index: Int?
    ) -> Bool {
        guard let pane = paneId.flatMap(pane(id:)) ?? focusedPane ?? panes.first else { return false }
        surface.reassign(toTab: id)
        pane.insert(surface, at: index)
        applyMetadata(metadata, for: surface.id)
        return true
    }

    /// Places a detached surface in a new split next to `paneId`.
    func adoptSurface(
        _ surface: TerminalSurface,
        metadata: SurfaceMetadata,
        splitting paneId: UUID,
        direction: SplitTree<TerminalPane>.NewDirection
    ) -> Bool {
        guard let pane = pane(id: paneId),
              let newTree = try? splitTree.inserting(view: TerminalPane(surface: surface), at: pane, direction: direction) else {
            return false
        }
        surface.reassign(toTab: id)
        splitTree = newTree
        applyMetadata(metadata, for: surface.id)
        return true
    }

    func closeSurface(_ surfaceId: UUID) -> Bool {
        guard let root = splitTree.root,
              let pane = pane(containing: surfaceId),
              let targetNode = root.find(id: pane.id) else {
            return false
        }

        let oldFocusedSurface = focusedSurface

        // Closing one of several pane tabs keeps the pane and selects a neighbor tab.
        if pane.surfaces.count > 1 {
            let wasFocused = focusedSurfaceId == surfaceId
            pane.remove(surfaceId: surfaceId)
            pruneSurfaceMetadata()
            if wasFocused, let nextSurface = pane.selectedSurface {
                focusedSurfaceId = nextSurface.id
                DispatchQueue.main.async {
                    nextSurface.hostedView.moveFocus(from: oldFocusedSurface?.hostedView)
                }
            }
            return true
        }

        let shouldMoveFocus = focusedSurfaceId == surfaceId
        let nextFocus: TerminalPane? = shouldMoveFocus
            ? findNextFocusTargetAfterClosing(node: targetNode)
            : nil

        splitTree = splitTree.removing(targetNode)
        // A closed split can race with shell-integration hooks that report ports/cwd.
        // Prune any per-surface metadata to the remaining leaves so the sidebar
        // doesn't display stale ports/directories.
        pruneSurfaceMetadata()

        if splitTree.isEmpty {
            focusedSurfaceId = nil
            return true
        }

        if shouldMoveFocus {
            focusedSurfaceId = nextFocus?.selectedSurface?.id
        }

        if focusedSurfaceId == nil {
            focusedSurfaceId = splitTree.root?.leftmostLeaf().selectedSurface?.id
        }

        if !splitTree.isSplit {
            splitTree = SplitTree(root: splitTree.root, zoomed: nil)
        }

        if shouldMoveFocus, let newFocusedSurface = focusedSurface {
            DispatchQueue.main.async {
                newFocusedSurface.hostedView.moveFocus(from: oldFocusedSurface?.hostedView)
            }
        }

        return true
    }
}

class TabManager: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var selectedTabId: UUID? {
        didSet {
            guard selectedTabId != oldValue else { return }
            let previousTabId = oldValue
            if let previousTabId,
               let previousSurfaceId = focusedSurfaceId(for: previousTabId) {
                lastFocusedSurfaceByTab[previousTabId] = previousSurfaceId
            }
            if !isNavigatingHistory, let selectedTabId {
                recordTabInHistory(selectedTabId)
            }
            DispatchQueue.main.async { [weak self] in
                self?.focusSelectedTabSurface(previousTabId: previousTabId)
                self?.updateWindowTitleForSelectedTab()
                if let selectedTabId = self?.selectedTabId {
                    self?.markFocusedPanelReadIfActive(tabId: selectedTabId)
                }
            }
        }
    }
    private var observers: [NSObjectProtocol] = []
    private var suppressFocusFlash = false
    private var lastFocusedSurfaceByTab: [UUID: UUID] = [:]

    // Recent tab history for back/forward navigation (like browser history)
    private var tabHistory: [UUID] = []
    private var historyIndex: Int = -1
    private var isNavigatingHistory = false
    private let maxHistorySize = 50

    private let sessionStore = SessionStore()
    private var sessionSaveTimer: Timer?
    /// How often the open layout is written to disk. Saving only at quit would lose
    /// everything on a crash, so the snapshot is refreshed periodically (unchanged
    /// snapshots are not rewritten).
    private static let sessionSaveInterval: TimeInterval = 2

    init() {
        if !restoreSession() {
            addTab()
        }
        startSessionAutosave()
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            guard let title = notification.userInfo?[GhosttyNotificationKey.title] as? String else { return }
            self.updateSurfaceTitle(tabId: tabId, surfaceId: surfaceId, title: title)
        })
    }

    var selectedTab: Tab? {
        guard let selectedTabId else { return nil }
        return tabs.first(where: { $0.id == selectedTabId })
    }

    var selectedSurface: TerminalSurface? {
        selectedTab?.focusedSurface
    }

    var isFindVisible: Bool {
        selectedSurface?.searchState != nil
    }

    var canUseSelectionForFind: Bool {
        selectedSurface?.hasSelection() == true
    }

    func startSearch() {
        guard let surface = selectedSurface else { return }
        if surface.searchState == nil {
            surface.searchState = TerminalSurface.SearchState()
        }
        NSLog("Find: startSearch tab=%@ surface=%@", surface.tabId.uuidString, surface.id.uuidString)
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: surface)
        _ = surface.performBindingAction("start_search")
    }

    func searchSelection() {
        guard let surface = selectedSurface else { return }
        if surface.searchState == nil {
            surface.searchState = TerminalSurface.SearchState()
        }
        NSLog("Find: searchSelection tab=%@ surface=%@", surface.tabId.uuidString, surface.id.uuidString)
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: surface)
        _ = surface.performBindingAction("search_selection")
    }

    func findNext() {
        _ = selectedSurface?.performBindingAction("search:next")
    }

    func findPrevious() {
        _ = selectedSurface?.performBindingAction("search:previous")
    }

    func hideFind() {
        selectedSurface?.searchState = nil
    }

    @discardableResult
    func addTab() -> Tab {
        let workingDirectory = preferredWorkingDirectoryForNewTab()
        let newTab = Tab(title: "Terminal \(tabs.count + 1)", workingDirectory: workingDirectory)
        let insertIndex = newTabInsertIndex()
        if insertIndex >= 0 && insertIndex <= tabs.count {
            tabs.insert(newTab, at: insertIndex)
        } else {
            tabs.append(newTab)
        }
        selectedTabId = newTab.id
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: newTab.id]
        )
        return newTab
    }

    private func newTabInsertIndex() -> Int {
        guard let selectedTabId,
              let index = tabs.firstIndex(where: { $0.id == selectedTabId }) else {
            return tabs.count
        }
        let selectedTab = tabs[index]
        if selectedTab.isPinned {
            let lastPinnedIndex = tabs.lastIndex(where: { $0.isPinned }) ?? -1
            return min(lastPinnedIndex + 1, tabs.count)
        }
        return min(index + 1, tabs.count)
    }

    private func preferredWorkingDirectoryForNewTab() -> String? {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else {
            return nil
        }
        let focusedDirectory = tab.focusedSurfaceId
            .flatMap { tab.surfaceDirectories[$0] }
        let candidate = focusedDirectory ?? tab.currentDirectory
        let normalized = normalizeDirectory(candidate)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : normalized
    }

    func moveTabToTop(_ tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        guard index != 0 else { return }
        let tab = tabs.remove(at: index)
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let insertIndex = tab.isPinned ? 0 : pinnedCount
        tabs.insert(tab, at: insertIndex)
    }

    func moveTabsToTop(_ tabIds: Set<UUID>) {
        guard !tabIds.isEmpty else { return }
        let selectedTabs = tabs.filter { tabIds.contains($0.id) }
        guard !selectedTabs.isEmpty else { return }
        let remainingTabs = tabs.filter { !tabIds.contains($0.id) }
        let selectedPinned = selectedTabs.filter { $0.isPinned }
        let selectedUnpinned = selectedTabs.filter { !$0.isPinned }
        let remainingPinned = remainingTabs.filter { $0.isPinned }
        let remainingUnpinned = remainingTabs.filter { !$0.isPinned }
        tabs = selectedPinned + remainingPinned + selectedUnpinned + remainingUnpinned
    }

    /// Moves a tab next to `targetId` (drag-and-drop reorder). Pinned and unpinned tabs stay
    /// in their own groups, so a drop across the boundary clamps to the edge of the tab's group.
    func moveTab(_ tabId: UUID, toPositionOf targetId: UUID) {
        guard tabId != targetId,
              let fromIndex = tabs.firstIndex(where: { $0.id == tabId }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetId }) else { return }
        let tab = tabs[fromIndex]
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let groupRange = tab.isPinned ? 0...(pinnedCount - 1) : pinnedCount...(tabs.count - 1)
        let destination = min(max(targetIndex, groupRange.lowerBound), groupRange.upperBound)
        guard destination != fromIndex else { return }
        tabs.remove(at: fromIndex)
        tabs.insert(tab, at: destination)
    }

    func setCustomTitle(tabId: UUID, title: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[index].setCustomTitle(title)
        if selectedTabId == tabId {
            updateWindowTitle(for: tabs[index])
        }
    }

    func clearCustomTitle(tabId: UUID) {
        setCustomTitle(tabId: tabId, title: nil)
    }

    func togglePin(tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[index]
        setPinned(tab, pinned: !tab.isPinned)
    }

    func setPinned(_ tab: Tab, pinned: Bool) {
        guard tab.isPinned != pinned else { return }
        tab.isPinned = pinned
        reorderTabForPinnedState(tab)
    }

    private func reorderTabForPinnedState(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let insertIndex = min(pinnedCount, tabs.count)
        tabs.insert(tab, at: insertIndex)
    }

    func updateSurfaceDirectory(tabId: UUID, surfaceId: UUID, directory: String) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let normalized = normalizeDirectory(directory)
        tab.updateSurfaceDirectory(surfaceId: surfaceId, directory: normalized)
    }

    private func normalizeDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            if !url.path.isEmpty {
                return url.path
            }
        }
        return trimmed
    }

    func closeTab(_ tab: Tab) {
        guard tabs.count > 1 else { return }

        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id)

        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: index)

            if selectedTabId == tab.id {
                if index > 0 {
                    selectedTabId = tabs[index - 1].id
                } else {
                    selectedTabId = tabs.first?.id
                }
            }
        }
    }

    func closeCurrentTab() {
        guard let selectedId = selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedId }) else { return }
        closeTab(tab)
    }

    func closeCurrentPanelWithConfirmation() {
        guard let selectedId = selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedId }),
              let focusedSurfaceId = tab.focusedSurfaceId else { return }
        closePanelWithConfirmation(tab: tab, surfaceId: focusedSurfaceId)
    }

    func closeCurrentTabWithConfirmation() {
        guard let selectedId = selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedId }) else { return }
        closeTabIfRunningProcess(tab)
    }

    func selectTab(_ tab: Tab) {
        selectedTabId = tab.id
    }

    private func confirmClose(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func closeTabIfRunningProcess(_ tab: Tab) {
        guard tabs.count > 1 else { return }
        if tabNeedsConfirmClose(tab),
           !confirmClose(
               title: "Close tab?",
               message: "This will close the current tab and all of its panels."
           ) {
            return
        }
        closeTab(tab)
    }

    private func closePanelWithConfirmation(tab: Tab, surfaceId: UUID) {
        guard tab.allSurfaces.count > 1 else {
            closeTabIfRunningProcess(tab)
            return
        }

        let surface = tab.surface(for: surfaceId)
        if surface?.needsConfirmClose() == true {
            guard confirmClose(
                title: "Close panel?",
                message: "This will close the current terminal in this tab."
            ) else { return }
        }

        _ = closeSurface(tabId: tab.id, surfaceId: surfaceId)
    }

    func closePanelWithConfirmation(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        closePanelWithConfirmation(tab: tab, surfaceId: surfaceId)
    }

    private func tabNeedsConfirmClose(_ tab: Tab) -> Bool {
        tab.allSurfaces.contains { $0.needsConfirmClose() }
    }

    func titleForTab(_ tabId: UUID) -> String? {
        tabs.first(where: { $0.id == tabId })?.title
    }

    func focusedSurfaceId(for tabId: UUID) -> UUID? {
        tabs.first(where: { $0.id == tabId })?.focusedSurfaceId
    }

    func rememberFocusedSurface(tabId: UUID, surfaceId: UUID) {
        lastFocusedSurfaceByTab[tabId] = surfaceId
    }

    func applyWindowBackgroundForSelectedTab() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let surface = tab.focusedSurface else { return }
        surface.applyWindowBackgroundIfActive()
    }

    /// Returns keyboard focus to the selected tab's terminal (e.g. after editing in the sidebar).
    func refocusSelectedSurface() {
        DispatchQueue.main.async { [weak self] in
            self?.focusSelectedTabSurface(previousTabId: nil)
        }
    }

    private func focusSelectedTabSurface(previousTabId: UUID?) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }
        if let restoredSurfaceId = lastFocusedSurfaceByTab[selectedTabId],
           tab.surface(for: restoredSurfaceId) != nil,
           tab.focusedSurfaceId != restoredSurfaceId {
            tab.focusedSurfaceId = restoredSurfaceId
        }
        guard let surface = tab.focusedSurface else { return }
        let previousSurface = previousTabId.flatMap { id in
            tabs.first(where: { $0.id == id })?.focusedSurface
        }
        surface.hostedView.moveFocus(from: previousSurface?.hostedView)
        surface.hostedView.ensureFocus(for: selectedTabId, surfaceId: surface.id)
    }

    private func markFocusedPanelReadIfActive(tabId: UUID) {
        let shouldSuppressFlash = suppressFocusFlash
        suppressFocusFlash = false
        guard !shouldSuppressFlash else { return }
        guard AppFocusState.isAppActive() else { return }
        guard let surfaceId = focusedSurfaceId(for: tabId) else { return }
        guard let notificationStore = AppDelegate.shared?.notificationStore else { return }
        guard notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) else { return }
        if let tab = tabs.first(where: { $0.id == tabId }) {
            tab.triggerNotificationFocusFlash(surfaceId: surfaceId, requiresSplit: false, shouldFocus: false)
        }
        notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId)
    }

    private func updateSurfaceTitle(tabId: UUID, surfaceId: UUID, title: String) {
        guard !title.isEmpty else { return }
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[index]

        // Store title per-surface
        tab.surfaceTitles[surfaceId] = title

        // Only update tab's display title if this surface is focused
        if tab.focusedSurfaceId == surfaceId {
            tab.applyProcessTitle(title)
            if selectedTabId == tabId {
                updateWindowTitle(for: tab)
            }
        }
    }

    func focusedSurfaceTitleDidChange(tabId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              let focusedSurfaceId = tab.focusedSurfaceId,
              let title = tab.surfaceTitles[focusedSurfaceId] else { return }
        tab.applyProcessTitle(title)
        if selectedTabId == tabId {
            updateWindowTitle(for: tab)
        }
    }

    private func updateWindowTitleForSelectedTab() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else {
            updateWindowTitle(for: nil)
            return
        }
        updateWindowTitle(for: tab)
    }

    private func updateWindowTitle(for tab: Tab?) {
        let title = windowTitle(for: tab)
        let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
        targetWindow?.title = title
    }

    private func windowTitle(for tab: Tab?) -> String {
        guard let tab else { return "CTerminal" }
        let trimmedTitle = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let trimmedDirectory = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDirectory.isEmpty ? "CTerminal" : trimmedDirectory
    }

    func focusTab(_ tabId: UUID, surfaceId: UUID? = nil, suppressFlash: Bool = false) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        selectedTabId = tabId
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: tabId]
        )

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.unhide(nil)
            if let window = NSApp.keyWindow ?? NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }

        if let surfaceId {
            if !suppressFlash {
                focusSurface(tabId: tabId, surfaceId: surfaceId)
            } else if let tab = tabs.first(where: { $0.id == tabId }) {
                tab.focusedSurfaceId = surfaceId
            }
        }
    }

    func focusTabFromNotification(_ tabId: UUID, surfaceId: UUID? = nil) {
        let wasSelected = selectedTabId == tabId
        let desiredSurfaceId = surfaceId ?? tabs.first(where: { $0.id == tabId })?.focusedSurfaceId
#if DEBUG
        if let desiredSurfaceId {
            AppDelegate.shared?.armJumpUnreadFocusRecord(tabId: tabId, surfaceId: desiredSurfaceId)
        }
#endif
        suppressFocusFlash = true
        focusTab(tabId, surfaceId: desiredSurfaceId, suppressFlash: true)
        if wasSelected {
            suppressFocusFlash = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self,
                  let tab = self.tabs.first(where: { $0.id == tabId }) else { return }
            let targetSurfaceId = desiredSurfaceId ?? tab.focusedSurfaceId
            guard let targetSurfaceId,
                  tab.surface(for: targetSurfaceId) != nil else { return }
            guard let notificationStore = AppDelegate.shared?.notificationStore else { return }
            guard notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: targetSurfaceId) else { return }
            tab.triggerNotificationFocusFlash(surfaceId: targetSurfaceId, requiresSplit: false, shouldFocus: true)
            notificationStore.markRead(forTabId: tabId, surfaceId: targetSurfaceId)
        }
    }

    func focusSurface(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.focusSurface(surfaceId)
    }

    func selectNextTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        selectedTabId = tabs[nextIndex].id
    }

    func selectPreviousTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = (currentIndex - 1 + tabs.count) % tabs.count
        selectedTabId = tabs[prevIndex].id
    }

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        selectedTabId = tabs[index].id
    }

    func selectLastTab() {
        guard let lastTab = tabs.last else { return }
        selectedTabId = lastTab.id
    }

    // MARK: - Recent Tab History Navigation

    private func recordTabInHistory(_ tabId: UUID) {
        // If we're not at the end of history, truncate forward history
        if historyIndex < tabHistory.count - 1 {
            tabHistory = Array(tabHistory.prefix(historyIndex + 1))
        }

        // Don't add duplicate consecutive entries
        if tabHistory.last == tabId {
            return
        }

        tabHistory.append(tabId)

        // Trim history if it exceeds max size
        if tabHistory.count > maxHistorySize {
            tabHistory.removeFirst(tabHistory.count - maxHistorySize)
        }

        historyIndex = tabHistory.count - 1
    }

    func navigateBack() {
        guard historyIndex > 0 else { return }

        // Find the previous valid tab in history (skip closed tabs)
        var targetIndex = historyIndex - 1
        while targetIndex >= 0 {
            let tabId = tabHistory[targetIndex]
            if tabs.contains(where: { $0.id == tabId }) {
                isNavigatingHistory = true
                historyIndex = targetIndex
                selectedTabId = tabId
                isNavigatingHistory = false
                return
            }
            // Remove closed tab from history
            tabHistory.remove(at: targetIndex)
            historyIndex -= 1
            targetIndex -= 1
        }
    }

    func navigateForward() {
        guard historyIndex < tabHistory.count - 1 else { return }

        // Find the next valid tab in history (skip closed tabs)
        let targetIndex = historyIndex + 1
        while targetIndex < tabHistory.count {
            let tabId = tabHistory[targetIndex]
            if tabs.contains(where: { $0.id == tabId }) {
                isNavigatingHistory = true
                historyIndex = targetIndex
                selectedTabId = tabId
                isNavigatingHistory = false
                return
            }
            // Remove closed tab from history
            tabHistory.remove(at: targetIndex)
            // Don't increment targetIndex since we removed the element
        }
    }

    var canNavigateBack: Bool {
        historyIndex > 0 && tabHistory.prefix(historyIndex).contains { tabId in
            tabs.contains { $0.id == tabId }
        }
    }

    var canNavigateForward: Bool {
        historyIndex < tabHistory.count - 1 && tabHistory.suffix(from: historyIndex + 1).contains { tabId in
            tabs.contains { $0.id == tabId }
        }
    }

    // MARK: - Session persistence

    /// Rebuilds tabs from the last saved session. Returns false when there is nothing to
    /// restore (no snapshot, restore disabled, or an unreadable file).
    private func restoreSession() -> Bool {
        guard SessionStore.isRestoreEnabled, let snapshot = sessionStore.load() else { return false }
        let restored = snapshot.tabs.map { Tab(restoring: $0) }
        guard !restored.isEmpty else { return false }
        tabs = restored
        let selectedIndex = snapshot.selectedTabIndex.flatMap { restored.indices.contains($0) ? $0 : nil } ?? 0
        let selected = restored[selectedIndex]
        selectedTabId = selected.id
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: selected.id]
        )
        NSLog("Session: restored %d tab(s)", restored.count)
        return true
    }

    private func startSessionAutosave() {
        let timer = Timer(timeInterval: Self.sessionSaveInterval, repeats: true) { [weak self] _ in
            self?.saveSession()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        sessionSaveTimer = timer
    }

    /// Writes the current layout to disk if it changed since the last write.
    func saveSession() {
        let snapshot = sessionSnapshot()
        guard !snapshot.tabs.isEmpty else { return }
        sessionStore.save(snapshot)
    }

    func newSplit(tabId: UUID, surfaceId: UUID, direction: SplitTree<TerminalPane>.NewDirection) -> UUID? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newSplit(from: surfaceId, direction: direction)?.id
    }

    func newSurfaceInFocusedPane() {
        guard let tab = selectedTab, let surfaceId = tab.focusedSurfaceId else { return }
        let previous = tab.focusedSurface
        guard let newSurface = tab.newSurface(inPaneOf: surfaceId) else { return }
        DispatchQueue.main.async {
            newSurface.hostedView.moveFocus(from: previous?.hostedView)
        }
    }

    func selectNextSurfaceInPane() {
        guard let tab = selectedTab, let surfaceId = tab.focusedSurfaceId else { return }
        _ = tab.cycleSurface(inPaneOf: surfaceId, by: 1)
    }

    func selectPreviousSurfaceInPane() {
        guard let tab = selectedTab, let surfaceId = tab.focusedSurfaceId else { return }
        _ = tab.cycleSurface(inPaneOf: surfaceId, by: -1)
    }

    func moveSplitFocus(tabId: UUID, surfaceId: UUID, direction: SplitTree<TerminalPane>.FocusDirection) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.moveFocus(from: surfaceId, direction: direction)
    }

    func resizeSplit(tabId: UUID, surfaceId: UUID, direction: SplitTree<TerminalPane>.Spatial.Direction, amount: UInt16) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.resizeSplit(from: surfaceId, direction: direction, amount: amount)
    }

    func equalizeSplits(tabId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        guard tab.splitTree.isSplit else { return false }
        tab.equalizeSplits()
        return true
    }

    func toggleSplitZoom(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.toggleZoom(on: surfaceId)
    }

    func closeSurface(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
        let tab = tabs[tabIndex]
        guard tab.closeSurface(surfaceId) else { return false }
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tabId, surfaceId: surfaceId)

        if tab.splitTree.isEmpty {
            if tabs.count > 1 {
                closeTab(tab)
            } else {
                let newSurface = TerminalSurface(
                    tabId: tab.id,
                    context: GHOSTTY_SURFACE_CONTEXT_TAB,
                    configTemplate: nil
                )
                tab.splitTree = SplitTree(view: TerminalPane(surface: newSurface))
                tab.focusSurface(newSurface.id)
            }
        }

        return true
    }
}

/// Where a dragged pane tab (terminal surface) is dropped.
enum SurfaceDropDestination: Equatable {
    /// As a tab of a pane, before the surface at `index` (nil: after the selected one).
    case pane(tabId: UUID, paneId: UUID, index: Int?)
    /// In a new split beside a pane.
    case split(tabId: UUID, paneId: UUID, direction: SplitTree<TerminalPane>.NewDirection)
    /// Into the focused pane of a sidebar tab.
    case tab(UUID)
    /// Into a brand-new sidebar tab, inserted after the source tab.
    case newTab
}

extension TabManager {
    func tab(containingSurface surfaceId: UUID) -> Tab? {
        tabs.first(where: { $0.pane(containing: surfaceId) != nil })
    }

    /// False for drops that would leave everything where it is.
    func canMoveSurface(_ surfaceId: UUID, to destination: SurfaceDropDestination) -> Bool {
        guard let sourceTab = tab(containingSurface: surfaceId),
              let sourcePane = sourceTab.pane(containing: surfaceId) else { return false }
        switch destination {
        case .pane(let tabId, let paneId, let index):
            guard let target = tabs.first(where: { $0.id == tabId }),
                  let pane = target.pane(id: paneId) else { return false }
            guard pane === sourcePane else { return true }
            guard let index, let from = pane.surfaces.firstIndex(where: { $0.id == surfaceId }) else { return false }
            return index != from && index != from + 1
        case .split(let tabId, let paneId, _):
            guard let target = tabs.first(where: { $0.id == tabId }),
                  let pane = target.pane(id: paneId) else { return false }
            return !(pane === sourcePane && pane.surfaces.count == 1)
        case .tab(let tabId):
            return tabId != sourceTab.id && tabs.contains(where: { $0.id == tabId })
        case .newTab:
            return sourceTab.allSurfaces.count > 1
        }
    }

    /// Moves a live terminal surface to a new place in this window without restarting it.
    /// Closes the source tab if the move empties it.
    func moveSurface(_ surfaceId: UUID, to destination: SurfaceDropDestination) {
        guard canMoveSurface(surfaceId, to: destination),
              let sourceTab = tab(containingSurface: surfaceId),
              let sourcePane = sourceTab.pane(containing: surfaceId) else { return }

        // Reordering inside one pane leaves the layout untouched.
        if case .pane(_, let paneId, let index?) = destination, paneId == sourcePane.id {
            sourcePane.move(surfaceId: surfaceId, toInsertionIndex: index)
            return
        }

        let targetTab: Tab?
        switch destination {
        case .pane(let tabId, _, _), .split(let tabId, _, _), .tab(let tabId):
            targetTab = tabs.first(where: { $0.id == tabId })
        case .newTab:
            targetTab = nil
        }

        let previousFocus = selectedTab?.focusedSurface
        let metadata = sourceTab.surfaceMetadata(for: surfaceId)
        guard let surface = sourceTab.detachSurface(surfaceId) else { return }
        if sourceTab.id != targetTab?.id {
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: sourceTab.id, surfaceId: surfaceId)
        }

        var placed = false
        if let targetTab {
            switch destination {
            case .pane(_, let paneId, let index):
                placed = targetTab.adoptSurface(surface, metadata: metadata, intoPane: paneId, at: index)
            case .split(_, let paneId, let direction):
                placed = targetTab.adoptSurface(surface, metadata: metadata, splitting: paneId, direction: direction)
            case .tab:
                placed = targetTab.adoptSurface(surface, metadata: metadata, intoPane: nil, at: nil)
            case .newTab:
                break
            }
        }

        let destinationTab: Tab
        if placed, let targetTab {
            destinationTab = targetTab
        } else {
            // New-tab drops, plus a fallback so a failed placement never kills the terminal.
            let newTab = Tab(adopting: surface, metadata: metadata)
            let insertIndex = tabs.firstIndex(where: { $0.id == sourceTab.id }).map { index in
                sourceTab.isPinned ? (tabs.lastIndex(where: { $0.isPinned }) ?? index) + 1 : index + 1
            } ?? tabs.count
            tabs.insert(newTab, at: min(insertIndex, tabs.count))
            destinationTab = newTab
        }

        if sourceTab.splitTree.isEmpty {
            closeTab(sourceTab)
        }

        selectedTabId = destinationTab.id
        destinationTab.focusSurface(surface.id)
        DispatchQueue.main.async {
            surface.hostedView.moveFocus(from: previousFocus === surface ? nil : previousFocus?.hostedView)
        }
    }
}

extension Notification.Name {
    static let ghosttyDidSetTitle = Notification.Name("ghosttyDidSetTitle")
    static let ghosttyDidFocusTab = Notification.Name("ghosttyDidFocusTab")
    static let ghosttyDidFocusSurface = Notification.Name("ghosttyDidFocusSurface")
}
