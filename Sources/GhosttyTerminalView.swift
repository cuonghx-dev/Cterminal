import Foundation
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import Darwin
import Carbon
import UniformTypeIdentifiers

private enum GhosttyPasteboardHelper {
    private static let selectionPasteboard = NSPasteboard(
        name: NSPasteboard.Name("com.mitchellh.ghostty.selection")
    )
    private static let utf8PlainTextType = NSPasteboard.PasteboardType("public.utf8-plain-text")
    private static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"
    private static let objectReplacementCharacter = Character(UnicodeScalar(0xFFFC)!)
    private static let maxClipboardImageSize = 10 * 1024 * 1024

    static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return .general
        case GHOSTTY_CLIPBOARD_SELECTION:
            return selectionPasteboard
        default:
            return nil
        }
    }

    static func stringContents(from pasteboard: NSPasteboard) -> String? {
        let types = pasteboard.types ?? []

        if types.contains(.fileURL) || types.contains(.URL),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            return urls
                .map { $0.isFileURL ? escapeForShell($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }

        if let plainText = plainTextContents(from: pasteboard) {
            return plainText
        }

        if let richText = richTextContents(from: pasteboard) {
            return richText
        }

        // Image-only clipboard (e.g. a screenshot): paste the path of a temporary
        // copy so CLI tools can read the image.
        return saveClipboardImageIfNeeded(from: pasteboard)
    }

    static func hasString(for location: ghostty_clipboard_e) -> Bool {
        guard let pasteboard = pasteboard(for: location) else { return false }
        let types = pasteboard.types ?? []
        if types.contains(.fileURL) || types.contains(.URL) ||
            types.contains(.html) || types.contains(.rtf) || types.contains(.rtfd) {
            return true
        }
        return types.contains(where: isPlainTextType) || hasImageData(in: pasteboard)
    }

    static func writeString(_ string: String, to location: ghostty_clipboard_e) {
        guard let pasteboard = pasteboard(for: location) else { return }
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private static func escapeForShell(_ value: String) -> String {
        if value.contains(where: { $0 == "\n" || $0 == "\r" }) {
            let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        var result = value
        for char in shellEscapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    private static func plainTextContents(from pasteboard: NSPasteboard) -> String? {
        let allTypes = pasteboard.types ?? []

        // Prefer UTF-8 plain text. Some apps (e.g. Qt-based ones) register
        // `com.apple.traditional-mac-plain-text` (Mac OS Roman) first, which turns
        // every non-Latin character into "?".
        for preferred in [utf8PlainTextType, NSPasteboard.PasteboardType.string] {
            guard allTypes.contains(preferred),
                  let value = pasteboard.string(forType: preferred),
                  !value.isEmpty else { continue }
            return value
        }

        // Apps like Raycast only publish alternate plain-text UTIs.
        for type in allTypes where type != utf8PlainTextType && type != .string && isPlainTextType(type) {
            guard let value = pasteboard.string(forType: type), !value.isEmpty else { continue }
            return value
        }

        return nil
    }

    private static func isPlainTextType(_ type: NSPasteboard.PasteboardType) -> Bool {
        if type == .string || type == utf8PlainTextType {
            return true
        }
        guard type != .html,
              type != .rtf,
              type != .rtfd,
              type != .fileURL,
              let utType = UTType(type.rawValue) else { return false }
        return utType.conforms(to: .plainText)
    }

    private static func richTextContents(from pasteboard: NSPasteboard) -> String? {
        let candidates: [(NSPasteboard.PasteboardType, NSAttributedString.DocumentType)] = [
            (.html, .html), (.rtf, .rtf), (.rtfd, .rtfd),
        ]
        for (type, documentType) in candidates {
            guard let data = pasteboard.data(forType: type)
                    ?? pasteboard.string(forType: type)?.data(using: .utf8),
                  let attributed = try? NSAttributedString(
                    data: data,
                    options: [
                        .documentType: documentType,
                        .characterEncoding: String.Encoding.utf8.rawValue,
                    ],
                    documentAttributes: nil
                  ) else { continue }

            // Attachments render as U+FFFC; drop them instead of pasting placeholders.
            let text = attributed.string
                .split(separator: objectReplacementCharacter, omittingEmptySubsequences: false)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func hasImageData(in pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.tiff) || types.contains(.png) {
            return true
        }
        return types.contains { type in
            guard let utType = UTType(type.rawValue) else { return false }
            return utType.conforms(to: .image)
        }
    }

    private static func imageRepresentation(in pasteboard: NSPasteboard) -> (data: Data, fileExtension: String)? {
        if let pngData = pasteboard.data(forType: .png) {
            return (pngData, "png")
        }

        for type in pasteboard.types ?? [] {
            guard type != .tiff,
                  let utType = UTType(type.rawValue),
                  utType.conforms(to: .image),
                  let data = pasteboard.data(forType: type),
                  let fileExtension = utType.preferredFilenameExtension,
                  !fileExtension.isEmpty else { continue }
            return (data, fileExtension)
        }

        // TIFF and anything else NSImage can decode: re-encode as PNG.
        guard hasImageData(in: pasteboard),
              let image = NSImage(pasteboard: pasteboard),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return (pngData, "png")
    }

    /// Saves an image-only clipboard to a temporary file and returns its shell-escaped path.
    private static func saveClipboardImageIfNeeded(from pasteboard: NSPasteboard) -> String? {
        guard let image = imageRepresentation(in: pasteboard),
              image.data.count <= maxClipboardImageSize else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let filename = "clipboard-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).\(image.fileExtension)"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try image.data.write(to: fileURL)
        } catch {
            return nil
        }
        return escapeForShell(fileURL.path)
    }
}

// Minimal Ghostty wrapper for terminal rendering
// This uses libghostty (GhosttyKit.xcframework) for actual terminal emulation

// MARK: - Ghostty App Singleton

class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var defaultBackgroundColor: NSColor = .windowBackgroundColor
    private(set) var defaultBackgroundOpacity: Double = 1.0
    let backgroundLogEnabled = {
        if ProcessInfo.processInfo.environment["CTER_DEBUG_BG"] == "1" {
            return true
        }
        if ProcessInfo.processInfo.environment["GHOSTTYTABS_DEBUG_BG"] == "1" {
            return true
        }
        if UserDefaults.standard.bool(forKey: "cterDebugBG") {
            return true
        }
        return UserDefaults.standard.bool(forKey: "GhosttyTabsDebugBG")
    }()
    private let backgroundLogURL = URL(fileURLWithPath: "/tmp/cter-bg.log")
    private var appObservers: [NSObjectProtocol] = []

    private init() {
        initializeGhostty()
    }

    private func initializeGhostty() {
        // Ensure TUI apps can use colors even if NO_COLOR is set in the launcher env.
        if getenv("NO_COLOR") != nil {
            unsetenv("NO_COLOR")
        }

        // Initialize Ghostty library first
        let result = ghostty_init(0, nil)
        if result != GHOSTTY_SUCCESS {
            print("Failed to initialize ghostty: \(result)")
            return
        }

        // Load config
        config = ghostty_config_new()
        guard let config = config else {
            print("Failed to create ghostty config")
            return
        }

        // Load default config
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        updateDefaultBackground(from: config)
        // Create runtime config with callbacks
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = { userdata in
            DispatchQueue.main.async {
                GhosttyApp.shared.tick()
            }
        }
        runtimeConfig.action_cb = { app, target, action in
            return GhosttyApp.shared.handleAction(target: target, action: action)
        }
        runtimeConfig.read_clipboard_cb = { userdata, location, state in
            // Read clipboard. Returning false tells Ghostty the request was not
            // started, so it frees the request state itself.
            guard let userdata else { return false }
            let surfaceView = Unmanaged<GhosttyNSView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = surfaceView.terminalSurface?.surface else { return false }

            let pasteboard = GhosttyPasteboardHelper.pasteboard(for: location)
            let value = pasteboard.flatMap { GhosttyPasteboardHelper.stringContents(from: $0) } ?? ""

            value.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
            return true
        }
        runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let userdata, let content else { return }
            let surfaceView = Unmanaged<GhosttyNSView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = surfaceView.terminalSurface?.surface else { return }

            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }
        runtimeConfig.write_clipboard_cb = { _, location, content, len, _ in
            // Write clipboard
            guard let content = content, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(len))

            var fallback: String?
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                let value = String(cString: dataPtr)

                if let mimePtr = item.mime {
                    let mime = String(cString: mimePtr)
                    if mime.hasPrefix("text/plain") {
                        GhosttyPasteboardHelper.writeString(value, to: location)
                        return
                    }
                }

                if fallback == nil {
                    fallback = value
                }
            }

            if let fallback {
                GhosttyPasteboardHelper.writeString(fallback, to: location)
            }
        }
        runtimeConfig.close_surface_cb = { userdata, _ in
            guard let userdata else { return }
            let surfaceView = Unmanaged<GhosttyNSView>.fromOpaque(userdata).takeUnretainedValue()
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id else {
                return
            }

            DispatchQueue.main.async {
                if let surface = surfaceView.terminalSurface,
                   surface.needsConfirmClose() {
                    AppDelegate.shared?.tabManager?.closePanelWithConfirmation(
                        tabId: tabId,
                        surfaceId: surfaceId
                    )
                    return
                }
                _ = AppDelegate.shared?.tabManager?.closeSurface(tabId: tabId, surfaceId: surfaceId)
            }
        }

        // Create app
        app = ghostty_app_new(&runtimeConfig, config)
        if app == nil {
            print("Failed to create ghostty app")
            return
        }

        #if os(macOS)
        if let app {
            ghostty_app_set_focus(app, NSApp.isActive)
        }

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        })

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        })
        #endif
    }

    func tick() {
        guard let app = app else { return }

        ghostty_app_tick(app)
    }

    func reloadConfiguration(soft: Bool = false) {
        guard let app else { return }
        if soft, let config {
            ghostty_app_update_config(app, config)
            GhosttyConfig.reloadShared()
            NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
            return
        }

        guard let newConfig = ghostty_config_new() else { return }
        ghostty_config_load_default_files(newConfig)
        ghostty_config_finalize(newConfig)
        ghostty_app_update_config(app, newConfig)
        updateDefaultBackground(from: newConfig)
        DispatchQueue.main.async {
            self.applyBackgroundToKeyWindow()
        }
        if let oldConfig = config {
            ghostty_config_free(oldConfig)
        }
        config = newConfig
        GhosttyConfig.reloadShared()
        NotificationCenter.default.post(name: .ghosttyConfigDidReload, object: nil)
    }

    func reloadConfiguration(for surface: ghostty_surface_t, soft: Bool = false) {
        if soft, let config {
            ghostty_surface_update_config(surface, config)
            return
        }

        guard let newConfig = ghostty_config_new() else { return }
        ghostty_config_load_default_files(newConfig)
        ghostty_config_finalize(newConfig)
        ghostty_surface_update_config(surface, newConfig)
        ghostty_config_free(newConfig)
    }

    func openConfigurationInTextEdit() {
        #if os(macOS)
        let path = ghosttyStringValue(ghostty_config_open_path())
        guard !path.isEmpty else { return }
        let fileURL = URL(fileURLWithPath: path)
        let editorURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([fileURL], withApplicationAt: editorURL, configuration: configuration)
        #endif
    }

    private func ghosttyStringValue(_ value: ghostty_string_s) -> String {
        defer { ghostty_string_free(value) }
        guard let ptr = value.ptr, value.len > 0 else { return "" }
        let rawPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        let buffer = UnsafeBufferPointer(start: rawPtr, count: Int(value.len))
        return String(decoding: buffer, as: UTF8.self)
    }

    private func updateDefaultBackground(from config: ghostty_config_t?) {
        guard let config else { return }

        var color = ghostty_config_color_s()
        let bgKey = "background"
        if ghostty_config_get(config, &color, bgKey, UInt(bgKey.lengthOfBytes(using: .utf8))) {
            defaultBackgroundColor = NSColor(
                red: CGFloat(color.r) / 255,
                green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255,
                alpha: 1.0
            )
        }

        var opacity: Double = 1.0
        let opacityKey = "background-opacity"
        _ = ghostty_config_get(config, &opacity, opacityKey, UInt(opacityKey.lengthOfBytes(using: .utf8)))
        defaultBackgroundOpacity = opacity
        if backgroundLogEnabled {
            logBackground("default background updated color=\(defaultBackgroundColor) opacity=\(String(format: "%.3f", defaultBackgroundOpacity))")
        }
    }

    private func performOnMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    private func splitDirection(from direction: ghostty_action_split_direction_e) -> SplitTree<TerminalPane>.NewDirection? {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: return .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: return .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: return .down
        case GHOSTTY_SPLIT_DIRECTION_UP: return .up
        default: return nil
        }
    }

    private func focusDirection(from direction: ghostty_action_goto_split_e) -> SplitTree<TerminalPane>.FocusDirection? {
        switch direction {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: return .previous
        case GHOSTTY_GOTO_SPLIT_NEXT: return .next
        case GHOSTTY_GOTO_SPLIT_UP: return .spatial(.up)
        case GHOSTTY_GOTO_SPLIT_DOWN: return .spatial(.down)
        case GHOSTTY_GOTO_SPLIT_LEFT: return .spatial(.left)
        case GHOSTTY_GOTO_SPLIT_RIGHT: return .spatial(.right)
        default: return nil
        }
    }

    private func resizeDirection(from direction: ghostty_action_resize_split_direction_e) -> SplitTree<TerminalPane>.Spatial.Direction? {
        switch direction {
        case GHOSTTY_RESIZE_SPLIT_UP: return .up
        case GHOSTTY_RESIZE_SPLIT_DOWN: return .down
        case GHOSTTY_RESIZE_SPLIT_LEFT: return .left
        case GHOSTTY_RESIZE_SPLIT_RIGHT: return .right
        default: return nil
        }
    }

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        if target.tag != GHOSTTY_TARGET_SURFACE {
            if action.tag == GHOSTTY_ACTION_DESKTOP_NOTIFICATION,
               let tabManager = AppDelegate.shared?.tabManager,
               let tabId = tabManager.selectedTabId {
                let actionTitle = action.action.desktop_notification.title
                    .flatMap { String(cString: $0) } ?? ""
                let actionBody = action.action.desktop_notification.body
                    .flatMap { String(cString: $0) } ?? ""
                let tabTitle = AppDelegate.shared?.tabManager?.titleForTab(tabId) ?? "Terminal"
                let command = actionTitle.isEmpty ? tabTitle : actionTitle
                let body = actionBody
                let surfaceId = tabManager.focusedSurfaceId(for: tabId)
                DispatchQueue.main.async {
                    tabManager.moveTabToTop(tabId)
                    TerminalNotificationStore.shared.addNotification(
                        tabId: tabId,
                        surfaceId: surfaceId,
                        title: command,
                        subtitle: "",
                        body: body
                    )
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_RELOAD_CONFIG {
                let soft = action.action.reload_config.soft
                performOnMain {
                    GhosttyApp.shared.reloadConfiguration(soft: soft)
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_COLOR_CHANGE,
               action.action.color_change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                let change = action.action.color_change
                defaultBackgroundColor = NSColor(
                    red: CGFloat(change.r) / 255,
                    green: CGFloat(change.g) / 255,
                    blue: CGFloat(change.b) / 255,
                    alpha: 1.0
                )
                if backgroundLogEnabled {
                    logBackground("OSC background change (app target) color=\(defaultBackgroundColor)")
                }
                DispatchQueue.main.async {
                    GhosttyApp.shared.applyBackgroundToKeyWindow()
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_CONFIG_CHANGE {
                updateDefaultBackground(from: action.action.config_change.config)
                DispatchQueue.main.async {
                    GhosttyApp.shared.applyBackgroundToKeyWindow()
                }
                return true
            }

            return false
        }
        guard let userdata = ghostty_surface_userdata(target.target.surface) else { return false }
        let surfaceView = Unmanaged<GhosttyNSView>.fromOpaque(userdata).takeUnretainedValue()

        switch action.tag {
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = splitDirection(from: action.action.new_split),
                  let tabManager = AppDelegate.shared?.tabManager else {
                return false
            }
            return performOnMain {
                tabManager.newSplit(tabId: tabId, surfaceId: surfaceId, direction: direction) != nil
            }
        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = focusDirection(from: action.action.goto_split),
                  let tabManager = AppDelegate.shared?.tabManager else {
                return false
            }
            return performOnMain {
                tabManager.moveSplitFocus(tabId: tabId, surfaceId: surfaceId, direction: direction)
            }
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = resizeDirection(from: action.action.resize_split.direction),
                  let tabManager = AppDelegate.shared?.tabManager else {
                return false
            }
            let amount = action.action.resize_split.amount
            return performOnMain {
                tabManager.resizeSplit(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    direction: direction,
                    amount: amount
                )
            }
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            guard let tabId = surfaceView.tabId,
                  let tabManager = AppDelegate.shared?.tabManager else {
                return false
            }
            return performOnMain {
                tabManager.equalizeSplits(tabId: tabId)
            }
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let tabManager = AppDelegate.shared?.tabManager else {
                return false
            }
            return performOnMain {
                tabManager.toggleSplitZoom(tabId: tabId, surfaceId: surfaceId)
            }
        case GHOSTTY_ACTION_SCROLLBAR:
            let scrollbar = GhosttyScrollbar(c: action.action.scrollbar)
            // Action callbacks can arrive off the main thread; macOS 26 rejects
            // AppKit/published state changes from background threads.
            DispatchQueue.main.async {
                surfaceView.scrollbar = scrollbar
                NotificationCenter.default.post(
                    name: .ghosttyDidUpdateScrollbar,
                    object: surfaceView,
                    userInfo: [GhosttyNotificationKey.scrollbar: scrollbar]
                )
            }
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let cellSize = CGSize(
                width: CGFloat(action.action.cell_size.width),
                height: CGFloat(action.action.cell_size.height)
            )
            DispatchQueue.main.async {
                surfaceView.cellSize = cellSize
                NotificationCenter.default.post(
                    name: .ghosttyDidUpdateCellSize,
                    object: surfaceView,
                    userInfo: [GhosttyNotificationKey.cellSize: cellSize]
                )
            }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let needle = action.action.start_search.needle.flatMap { String(cString: $0) }
            DispatchQueue.main.async {
                if let searchState = terminalSurface.searchState {
                    if let needle, !needle.isEmpty {
                        searchState.needle = needle
                    }
                } else {
                    terminalSurface.searchState = TerminalSurface.SearchState(needle: needle ?? "")
                }
                NotificationCenter.default.post(name: .ghosttySearchFocus, object: terminalSurface)
            }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            DispatchQueue.main.async {
                terminalSurface.searchState = nil
            }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let rawTotal = action.action.search_total.total
            let total: UInt? = rawTotal >= 0 ? UInt(rawTotal) : nil
            DispatchQueue.main.async {
                terminalSurface.searchState?.total = total
            }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let rawSelected = action.action.search_selected.selected
            let selected: UInt? = rawSelected >= 0 ? UInt(rawSelected) : nil
            DispatchQueue.main.async {
                terminalSurface.searchState?.selected = selected
            }
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            let title = action.action.set_title.title
                .flatMap { String(cString: $0) } ?? ""
            if let tabId = surfaceView.tabId,
               let surfaceId = surfaceView.terminalSurface?.id {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .ghosttyDidSetTitle,
                        object: surfaceView,
                        userInfo: [
                            GhosttyNotificationKey.tabId: tabId,
                            GhosttyNotificationKey.surfaceId: surfaceId,
                            GhosttyNotificationKey.title: title,
                        ]
                    )
                }
            }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id else { return true }
            let pwd = action.action.pwd.pwd.flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                AppDelegate.shared?.tabManager?.updateSurfaceDirectory(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    directory: pwd
                )
            }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let tabId = surfaceView.tabId else { return true }
            let surfaceId = surfaceView.terminalSurface?.id
            let actionTitle = action.action.desktop_notification.title
                .flatMap { String(cString: $0) } ?? ""
            let actionBody = action.action.desktop_notification.body
                .flatMap { String(cString: $0) } ?? ""
            let tabTitle = AppDelegate.shared?.tabManager?.titleForTab(tabId) ?? "Terminal"
            let command = actionTitle.isEmpty ? tabTitle : actionTitle
            let body = actionBody
            DispatchQueue.main.async {
                AppDelegate.shared?.tabManager?.moveTabToTop(tabId)
                TerminalNotificationStore.shared.addNotification(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    title: command,
                    subtitle: "",
                    body: body
                )
            }
            return true
        case GHOSTTY_ACTION_COLOR_CHANGE:
            if action.action.color_change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                let change = action.action.color_change
                let newColor = NSColor(
                    red: CGFloat(change.r) / 255,
                    green: CGFloat(change.g) / 255,
                    blue: CGFloat(change.b) / 255,
                    alpha: 1.0
                )
                DispatchQueue.main.async { [self] in
                    surfaceView.backgroundColor = newColor
                    surfaceView.applySurfaceBackground()
                    if backgroundLogEnabled {
                        logBackground("OSC background change tab=\(surfaceView.tabId?.uuidString ?? "unknown") color=\(surfaceView.backgroundColor?.description ?? "nil")")
                    }
                    surfaceView.applyWindowBackgroundIfActive()
                }
            }
            return true
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            updateDefaultBackground(from: action.action.config_change.config)
            DispatchQueue.main.async {
                surfaceView.applyWindowBackgroundIfActive()
            }
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            let soft = action.action.reload_config.soft
            return performOnMain {
                if let surface = surfaceView.terminalSurface?.surface {
                    GhosttyApp.shared.reloadConfiguration(for: surface, soft: soft)
                } else {
                    GhosttyApp.shared.reloadConfiguration(soft: soft)
                }
                return true
            }
        case GHOSTTY_ACTION_KEY_SEQUENCE:
            return performOnMain {
                surfaceView.updateKeySequence(action.action.key_sequence)
                return true
            }
        case GHOSTTY_ACTION_KEY_TABLE:
            return performOnMain {
                surfaceView.updateKeyTable(action.action.key_table)
                return true
            }
        default:
            return false
        }
    }

    private func applyBackgroundToKeyWindow() {
        guard let window = activeMainWindow() else { return }
        // Check if sidebar uses behindWindow blur - if so, keep window non-opaque
        let sidebarBlendMode = UserDefaults.standard.string(forKey: "sidebarBlendMode") ?? "behindWindow"
        if sidebarBlendMode == "behindWindow" && !WindowGlassEffect.isAvailable {
            window.backgroundColor = .clear
            window.isOpaque = false
            if backgroundLogEnabled {
                logBackground("applied transparent window for behindWindow blur")
            }
        } else {
            let color = defaultBackgroundColor.withAlphaComponent(defaultBackgroundOpacity)
            window.backgroundColor = color
            window.isOpaque = color.alphaComponent >= 1.0
            if backgroundLogEnabled {
                logBackground("applied default window background color=\(color) opacity=\(String(format: "%.3f", color.alphaComponent))")
            }
        }
    }

    private func activeMainWindow() -> NSWindow? {
        let keyWindow = NSApp.keyWindow
        if keyWindow?.identifier?.rawValue == "cter.main" {
            return keyWindow
        }
        return NSApp.windows.first(where: { $0.identifier?.rawValue == "cter.main" })
    }

    func logBackground(_ message: String) {
        let line = "cter bg: \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: backgroundLogURL.path) == false {
                FileManager.default.createFile(atPath: backgroundLogURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: backgroundLogURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

}

// MARK: - Terminal Surface (owns the ghostty_surface_t lifecycle)

final class TerminalSurface: Identifiable, ObservableObject {
    final class SearchState: ObservableObject {
        @Published var needle: String
        @Published var selected: UInt?
        @Published var total: UInt?

        init(needle: String = "") {
            self.needle = needle
            self.selected = nil
            self.total = nil
        }
    }

    private(set) var surface: ghostty_surface_t?
    private weak var attachedView: GhosttyNSView?
    private var isVisible = true
    let id: UUID
    private(set) var tabId: UUID
    private let surfaceContext: ghostty_surface_context_e
    private let configTemplate: ghostty_surface_config_s?
    private let workingDirectory: String?
    let hostedView: GhosttySurfaceScrollView
    private let surfaceView: GhosttyNSView
    @Published var searchState: SearchState? = nil {
        didSet {
            if let searchState {
                hostedView.cancelFocusRequest()
                NSLog("Find: search state created tab=%@ surface=%@", tabId.uuidString, id.uuidString)
                searchNeedleCancellable = searchState.$needle
                    .removeDuplicates()
                    .map { needle -> AnyPublisher<String, Never> in
                        if needle.isEmpty || needle.count >= 3 {
                            return Just(needle).eraseToAnyPublisher()
                        }

                        return Just(needle)
                            .delay(for: .milliseconds(300), scheduler: DispatchQueue.main)
                            .eraseToAnyPublisher()
                    }
                    .switchToLatest()
                    .sink { [weak self] needle in
                        NSLog("Find: needle updated tab=%@ surface=%@ needle=%@", self?.tabId.uuidString ?? "unknown", self?.id.uuidString ?? "unknown", needle)
                        _ = self?.performBindingAction("search:\(needle)")
                    }
            } else if oldValue != nil {
                searchNeedleCancellable = nil
                NSLog("Find: search state cleared tab=%@ surface=%@", tabId.uuidString, id.uuidString)
                _ = performBindingAction("end_search")
            }
        }
    }
    private var searchNeedleCancellable: AnyCancellable?
    /// Last focus state sent to Ghostty; nil until the first `setFocus`.
    private var lastFocusState: Bool?

    init(
        tabId: UUID,
        context: ghostty_surface_context_e,
        configTemplate: ghostty_surface_config_s?,
        workingDirectory: String? = nil
    ) {
        self.id = UUID()
        self.tabId = tabId
        self.surfaceContext = context
        self.configTemplate = configTemplate
        self.workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let view = GhosttyNSView(frame: .zero)
        self.surfaceView = view
        self.hostedView = GhosttySurfaceScrollView(surfaceView: view)
        // Surface is created when attached to a view
        hostedView.attachSurface(self)
    }

    /// Re-homes this surface in another tab (drag-and-drop between sidebar tabs). The shell's
    /// `CTER_TAB_ID` env var keeps the original value; the running process can't be updated.
    func reassign(toTab newTabId: UUID) {
        guard tabId != newTabId else { return }
        tabId = newTabId
        surfaceView.tabId = newTabId
    }

    private func scaleFactors(for view: GhosttyNSView) -> (x: CGFloat, y: CGFloat, layer: CGFloat) {
        let layerScale = view.window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        return (layerScale, layerScale, layerScale)
    }

    func attachToView(_ view: GhosttyNSView) {
        // If already attached to this view, nothing to do
        if attachedView === view && surface != nil {
            updateMetalLayer(for: view)
            refreshForCurrentDisplay()
            return
        }

        if let attachedView, attachedView !== view {
            return
        }

        attachedView = view

        // If surface doesn't exist yet, create it
        if surface == nil {
            createSurface(for: view)
        }
    }

    private func createSurface(for view: GhosttyNSView) {
        guard let app = GhosttyApp.shared.app else {
            print("Ghostty app not initialized")
            return
        }

        let scaleFactors = scaleFactors(for: view)

        updateMetalLayer(for: view)

        var surfaceConfig = configTemplate ?? ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.userdata = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.scale_factor = scaleFactors.layer
        surfaceConfig.context = surfaceContext
        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        defer {
            for (key, value) in envStorage {
                free(key)
                free(value)
            }
        }

        // IMPORTANT:
        // `surfaceConfig.env_vars` are *overrides* layered on top of Ghostty's
        // default subprocess environment.
        //
        // Do not seed this map with the full app environment: that would
        // bypass Ghostty's env filtering (e.g. LANGUAGE, Xcode DYLD vars) by
        // re-introducing stripped variables via overrides.
        var env: [String: String] = [:]
        if surfaceConfig.env_var_count > 0, let existingEnv = surfaceConfig.env_vars {
            let count = Int(surfaceConfig.env_var_count)
            if count > 0 {
                for i in 0..<count {
                    let item = existingEnv[i]
                    if let key = String(cString: item.key, encoding: .utf8),
                       let value = String(cString: item.value, encoding: .utf8) {
                        env[key] = value
                    }
                }
            }
        }

        env["CTER_PANEL_ID"] = id.uuidString
        env["CTER_TAB_ID"] = tabId.uuidString
        env["CTER_SOCKET_PATH"] = SocketControlSettings.socketPath()

        if let cliBinPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            let currentPath = env["PATH"]
                ?? getenv("PATH").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            if !currentPath.split(separator: ":").contains(Substring(cliBinPath)) {
                let separator = currentPath.isEmpty ? "" : ":"
                env["PATH"] = "\(cliBinPath)\(separator)\(currentPath)"
            }
        }

        // Shell integration: inject ZDOTDIR wrapper for zsh
        let shellIntegrationEnabled = UserDefaults.standard.object(forKey: "sidebarShellIntegration") as? Bool ?? true
        if shellIntegrationEnabled,
           let integrationDir = Bundle.main.resourceURL?
            .appendingPathComponent("shell-integration").path {
            env["CTER_SHELL_INTEGRATION"] = "1"
            env["CTER_SHELL_INTEGRATION_DIR"] = integrationDir

            // Prefer the per-surface environment (from Ghostty config/env vars),
            // falling back to the app's environment. This avoids regressions when
            // users override SHELL/ZDOTDIR at the surface level.
            let shell = (env["SHELL"]?.isEmpty == false ? env["SHELL"] : nil)
                ?? getenv("SHELL").map { String(cString: $0) }
                ?? ProcessInfo.processInfo.environment["SHELL"]
                ?? "/bin/zsh"
            let shellName = URL(fileURLWithPath: shell).lastPathComponent
            if shellName == "zsh" {
                // GhosttyKit already injects zsh integration by setting ZDOTDIR to
                // Ghostty's integration directory. We still need to set ZDOTDIR
                // to our wrapper to load Resources/shell-integration/.zshenv,
                // but we must not treat Ghostty's injected ZDOTDIR as the user's
                // "real" ZDOTDIR (or zsh history will end up inside the app bundle).
                //
                // If the user explicitly set ZDOTDIR, preserve it in CTER_ZSH_ZDOTDIR
                // so our wrapper can restore it immediately.
                let candidateZdotdir = (env["ZDOTDIR"]?.isEmpty == false ? env["ZDOTDIR"] : nil)
                    ?? getenv("ZDOTDIR").map { String(cString: $0) }
                    ?? (ProcessInfo.processInfo.environment["ZDOTDIR"]?.isEmpty == false ? ProcessInfo.processInfo.environment["ZDOTDIR"] : nil)

                if let candidateZdotdir, !candidateZdotdir.isEmpty {
                    var isGhosttyInjected = false
                    let ghosttyResources = (env["GHOSTTY_RESOURCES_DIR"]?.isEmpty == false ? env["GHOSTTY_RESOURCES_DIR"] : nil)
                        ?? getenv("GHOSTTY_RESOURCES_DIR").map { String(cString: $0) }
                        ?? (ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]?.isEmpty == false ? ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] : nil)
                    if let ghosttyResources {
                        let ghosttyZdotdir = URL(fileURLWithPath: ghosttyResources)
                            .appendingPathComponent("shell-integration/zsh").path
                        isGhosttyInjected = (candidateZdotdir == ghosttyZdotdir)
                    }
                    if !isGhosttyInjected {
                        env["CTER_ZSH_ZDOTDIR"] = candidateZdotdir
                    }
                }

                env["ZDOTDIR"] = integrationDir
            }
        }

        if !env.isEmpty {
            envVars.reserveCapacity(env.count)
            envStorage.reserveCapacity(env.count)
            for (key, value) in env {
                guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
                envStorage.append((keyPtr, valuePtr))
                envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
            }
        }

        let createSurface = { [self] in
            if !envVars.isEmpty {
                let envVarsCount = envVars.count
                envVars.withUnsafeMutableBufferPointer { buffer in
                    surfaceConfig.env_vars = buffer.baseAddress
                    surfaceConfig.env_var_count = envVarsCount
                    self.surface = ghostty_surface_new(app, &surfaceConfig)
                }
            } else {
                self.surface = ghostty_surface_new(app, &surfaceConfig)
            }
        }

        if let workingDirectory, !workingDirectory.isEmpty {
            workingDirectory.withCString { cWorkingDir in
                surfaceConfig.working_directory = cWorkingDir
                createSurface()
            }
        } else {
            createSurface()
        }

        if surface == nil {
            print("Failed to create ghostty surface")
            return
        }

        ghostty_surface_set_content_scale(surface, scaleFactors.x, scaleFactors.y)
        ghostty_surface_set_size(
            surface,
            UInt32(view.bounds.width * scaleFactors.x),
            UInt32(view.bounds.height * scaleFactors.y)
        )
        // Ghostty needs the display id to drive vsync. Without it the renderer can believe
        // vsync is running but never deliver frames, which looks like a frozen terminal.
        assertDisplayID(for: view)
        if !isVisible {
            ghostty_surface_set_occlusion(surface, false)
        }
        ghostty_surface_refresh(surface)
    }

    /// Hidden surfaces (background tabs, unselected pane tabs) stay mounted, so tell Ghostty
    /// they are occluded to pause their renderer; otherwise every open terminal keeps drawing.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
        if visible {
            refreshForCurrentDisplay()
        }
    }

    /// Reassert the display id and force a redraw. Used after the view is reparented
    /// (split churn) when its size is unchanged, so no resize-driven refresh happens.
    func refreshForCurrentDisplay() {
        guard let surface, let view = attachedView, view.window != nil else { return }
        assertDisplayID(for: view)
        ghostty_surface_refresh(surface)
    }

    private func assertDisplayID(for view: GhosttyNSView) {
        guard let surface,
              let displayID = (view.window?.screen ?? NSScreen.main)?.displayID,
              displayID != 0 else { return }
        ghostty_surface_set_display_id(surface, displayID)
    }

    private func updateMetalLayer(for view: GhosttyNSView) {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.contentsScale = scale
            if view.bounds.width > 0 && view.bounds.height > 0 {
                metalLayer.drawableSize = CGSize(
                    width: view.bounds.width * scale,
                    height: view.bounds.height * scale
                )
            }
        }
    }

    func updateSize(width: CGFloat, height: CGFloat, xScale: CGFloat, yScale: CGFloat, layerScale: CGFloat) {
        guard let surface = surface else { return }
        ghostty_surface_set_content_scale(surface, xScale, yScale)
        ghostty_surface_set_size(surface, UInt32(width * xScale), UInt32(height * yScale))
        ghostty_surface_refresh(surface)

        if let view = attachedView, let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.contentsScale = layerScale
            metalLayer.drawableSize = CGSize(width: width * layerScale, height: height * layerScale)
        }
    }

    func applyWindowBackgroundIfActive() {
        surfaceView.applyWindowBackgroundIfActive()
    }

    /// Keep `lastFocusState` in sync when the hosted view's responder chain calls
    /// `ghostty_surface_set_focus` directly; otherwise a later `setFocus` is
    /// wrongly deduplicated against a stale value.
    func recordExternalFocusState(_ focused: Bool) {
        lastFocusState = focused
    }

    func setFocus(_ focused: Bool) {
        guard let surface = surface else { return }
        // Only send focus events when the state changes; redundant focus events
        // make zsh themes like Powerlevel10k redraw the prompt.
        guard focused != lastFocusState else { return }
        lastFocusState = focused
        ghostty_surface_set_focus(surface, focused)

        // Focusing a surface while it is being reparented can start Ghostty's display link
        // before the display id is valid. Reasserting it after focus restarts the link.
        if let view = attachedView, view.window != nil {
            assertDisplayID(for: view)
        }
    }

    func needsConfirmClose() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    func sendText(_ text: String) {
        guard let surface = surface else { return }
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    func hasSelection() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    deinit {
        if let surface = surface {
            ghostty_surface_free(surface)
        }
    }
}

// MARK: - Ghostty Surface View

class GhosttyNSView: NSView, NSUserInterfaceValidations {
    private static let focusDebugEnabled: Bool = {
        if ProcessInfo.processInfo.environment["CTER_FOCUS_DEBUG"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cterFocusDebug")
    }()
    fileprivate static func focusLog(_ message: String) {
        guard focusDebugEnabled else { return }
        NSLog("[FOCUSDBG] %@", message)
    }

    weak var terminalSurface: TerminalSurface?
    private var surfaceAttached = false
    var scrollbar: GhosttyScrollbar?
    var cellSize: CGSize = .zero
    var desiredFocus: Bool = false
    var tabId: UUID?
    var onFocus: (() -> Void)?
    var onTriggerFlash: (() -> Void)?
    var backgroundColor: NSColor?
    private var keySequence: [ghostty_input_trigger_s] = []
    private var keyTables: [String] = []
    private var eventMonitor: Any?
    private var trackingArea: NSTrackingArea?
    private var windowObserver: NSObjectProtocol?
    private var lastSurfaceSize: CGSize = .zero
    private var lastContentScale: CGSize = .zero
    private var lastLayerScale: CGFloat = 0
    private var hasSurfaceMetrics = false
    private var lastScrollEventTime: CFTimeInterval = 0

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        return metalLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        installEventMonitor()
        updateTrackingAreas()
    }

    private func effectiveBackgroundColor() -> NSColor {
        let base = backgroundColor ?? GhosttyApp.shared.defaultBackgroundColor
        let opacity = GhosttyApp.shared.defaultBackgroundOpacity
        return base.withAlphaComponent(opacity)
    }

    func applySurfaceBackground() {
        let color = effectiveBackgroundColor()
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.backgroundColor = color.cgColor
            metalLayer.isOpaque = color.alphaComponent >= 1.0
        }
        terminalSurface?.hostedView.setBackgroundColor(color)
    }

    func applyWindowBackgroundIfActive() {
        guard let window else { return }
        if let tabId, let selectedId = AppDelegate.shared?.tabManager?.selectedTabId, tabId != selectedId {
            return
        }
        applySurfaceBackground()
        let color = effectiveBackgroundColor()
        // Check if sidebar uses behindWindow blur - if so, keep window non-opaque
        let sidebarBlendMode = UserDefaults.standard.string(forKey: "sidebarBlendMode") ?? "behindWindow"
        if sidebarBlendMode == "behindWindow" && !WindowGlassEffect.isAvailable {
            window.backgroundColor = .clear
            window.isOpaque = false
        } else {
            window.backgroundColor = color
            window.isOpaque = color.alphaComponent >= 1.0
        }
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground("applied window background tab=\(tabId?.uuidString ?? "unknown") color=\(color) opacity=\(String(format: "%.3f", color.alphaComponent))")
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            return self?.localEventHandler(event) ?? event
        }
    }

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .scrollWheel:
            return localEventScrollWheel(event)
        default:
            return event
        }
    }

    private func localEventScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard let window,
              let eventWindow = event.window,
              window == eventWindow else { return event }

        let location = convert(event.locationInWindow, from: nil)
        guard hitTest(location) == self else { return event }

        Self.focusLog("localEventScrollWheel: window=\(ObjectIdentifier(window)) firstResponder=\(String(describing: window.firstResponder))")
        return event
    }

    func attachSurface(_ surface: TerminalSurface) {
        terminalSurface = surface
        tabId = surface.tabId
        surfaceAttached = false
        hasSurfaceMetrics = false
        attachSurfaceIfNeeded()
    }

    private func attachSurfaceIfNeeded() {
        guard !surfaceAttached else { return }
        guard let terminalSurface = terminalSurface else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard window != nil else { return }

        surfaceAttached = true
        terminalSurface.attachToView(self)
        terminalSurface.setFocus(desiredFocus)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        if let window {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] notification in
                self?.windowDidChangeScreen(notification)
            }
            attachSurfaceIfNeeded()
            updateSurfaceSize()
            // Force a redraw even when the size is unchanged (e.g. after split reparenting).
            terminalSurface?.refreshForCurrentDisplay()
            applySurfaceBackground()
            applyWindowBackgroundIfActive()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateSurfaceSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        attachSurfaceIfNeeded()
        updateSurfaceSize()
        invalidateTextInputCoordinates()
    }

    override func layout() {
        super.layout()
        attachSurfaceIfNeeded()
        invalidateTextInputCoordinates()
    }

    override var isOpaque: Bool { false }

    private func updateSurfaceSize() {
        guard let terminalSurface = terminalSurface else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let layerScale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let xScale = layerScale
        let yScale = layerScale
        if hasSurfaceMetrics {
            let sameSize = nearlyEqual(lastSurfaceSize.width, bounds.width, epsilon: 0.01)
                && nearlyEqual(lastSurfaceSize.height, bounds.height, epsilon: 0.01)
            let sameScale = nearlyEqual(lastContentScale.width, xScale)
                && nearlyEqual(lastContentScale.height, yScale)
                && nearlyEqual(lastLayerScale, layerScale)
            if sameSize && sameScale {
                return
            }
        }
        lastSurfaceSize = bounds.size
        lastContentScale = CGSize(width: xScale, height: yScale)
        lastLayerScale = layerScale
        hasSurfaceMetrics = true
        terminalSurface.updateSize(
            width: bounds.width,
            height: bounds.height,
            xScale: xScale,
            yScale: yScale,
            layerScale: layerScale
        )
    }

    private func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) <= epsilon
    }

    // Convenience accessor for the ghostty surface
    private var surface: ghostty_surface_t? {
        terminalSurface?.surface
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    // MARK: - Input Handling

    @IBAction func copy(_ sender: Any?) {
        _ = performBindingAction("copy_to_clipboard")
    }

    @IBAction func paste(_ sender: Any?) {
        _ = performBindingAction("paste_from_clipboard")
    }

    @IBAction func pasteAsPlainText(_ sender: Any?) {
        _ = performBindingAction("paste_from_clipboard")
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            guard let surface = surface else { return false }
            return ghostty_surface_has_selection(surface)
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)):
            return GhosttyPasteboardHelper.hasString(for: GHOSTTY_CLIPBOARD_STANDARD)
        default:
            return true
        }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Accessibility

    /// Expose the terminal as an editable text area; voice input tools target
    /// AX text areas for text insertion.
    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilityHelp() -> String? {
        "Terminal content area"
    }

    override func accessibilityValue() -> Any? {
        // No full terminal text snapshot lives in this layer; expose the selection
        // (or empty) so AX clients still treat this as an editable text area.
        accessibilitySelectedText() ?? ""
    }

    override func setAccessibilityValue(_ value: Any?) {
        let content: String
        switch value {
        case let v as NSAttributedString:
            content = v.string
        case let v as String:
            content = v
        default:
            return
        }
        guard !content.isEmpty else { return }

        let inject = {
            self.externalCommittedTextDepth += 1
            defer { self.externalCommittedTextDepth -= 1 }
            self.insertText(content, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        if Thread.isMainThread {
            inject()
        } else {
            DispatchQueue.main.async(execute: inject)
        }
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        selectedRange()
    }

    override func accessibilitySelectedText() -> String? {
        guard let snapshot = readSelectionSnapshot() else { return nil }
        return snapshot.string.isEmpty ? nil : snapshot.string
    }

    fileprivate struct SelectionSnapshot {
        let range: NSRange
        let string: String
        let topLeft: CGPoint
    }

    fileprivate func readSelectionSnapshot() -> SelectionSnapshot? {
        guard let surface else { return nil }

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        let selected: String
        if let ptr = text.text, text.text_len > 0 {
            selected = String(decoding: Data(bytes: ptr, count: Int(text.text_len)), as: UTF8.self)
        } else {
            selected = ""
        }
        return SelectionSnapshot(
            range: NSRange(location: Int(text.offset_start), length: Int(text.offset_len)),
            string: selected,
            topLeft: CGPoint(x: text.tl_px_x, y: text.tl_px_y)
        )
    }

    fileprivate func invalidateTextInputCoordinates(selectionChanged: Bool = false) {
        guard let inputContext else { return }
        inputContext.invalidateCharacterCoordinates()
        if #available(macOS 15.4, *), selectionChanged {
            inputContext.textInputClientDidUpdateSelection()
        }
    }

    fileprivate var hasUsableFocusGeometry: Bool {
        bounds.width > 1 && bounds.height > 1
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface = surface {
            let now = CACurrentMediaTime()
            let deltaMs = (now - lastScrollEventTime) * 1000
            Self.focusLog("becomeFirstResponder: surface=\(terminalSurface?.id.uuidString ?? "nil") deltaSinceScrollMs=\(String(format: "%.2f", deltaMs))")
            // A hidden (background pane tab) or not-yet-laid-out view must not claim
            // UI focus; doing so during split churn makes focus ping-pong between panes.
            if hasUsableFocusGeometry && !isHiddenOrHasHiddenAncestor {
                onFocus?()
            }
#if DEBUG
            if let terminalSurface {
                AppDelegate.shared?.recordJumpUnreadFocusIfExpected(
                    tabId: terminalSurface.tabId,
                    surfaceId: terminalSurface.id
                )
            }
#endif
            terminalSurface?.recordExternalFocusState(true)
            ghostty_surface_set_focus(surface, true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        return super.resignFirstResponder()
    }

    // For NSTextInputClient - accumulates text during key events
    private var keyTextAccumulator: [String]? = nil
    private var markedText = NSMutableAttributedString()
    private var markedSelectedRange = NSRange(location: 0, length: 0)
    private var numpadIMECommitDeduplicator = NumpadIMECommitDeduplicator()
    /// > 0 while text arrives from an external tool (AX value, insertText: action).
    private var externalCommittedTextDepth = 0
    // Set when interpretKeyEvents asks for deleteBackward: during the current keyDown.
    private var keyRequestedDeleteBackward = false
    private var lastPerformKeyEvent: TimeInterval?

    // Prevents NSBeep for unimplemented actions from interpretKeyEvents
    override func doCommand(by selector: Selector) {
        // Otherwise empty - prevents system beep on unhandled key commands
        if keyTextAccumulator != nil, selector == #selector(deleteBackward(_:)) {
            keyRequestedDeleteBackward = true
        }
    }

    /// Some third-party voice input apps commit text through the responder-chain
    /// `insertText:` action (single-argument form); route it into NSTextInputClient.
    override func insertText(_ insertString: Any) {
        externalCommittedTextDepth += 1
        defer { externalCommittedTextDepth -= 1 }
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard window?.firstResponder === self else { return false }
        guard let surface = surface else { return false }

        // If the IME is composing (marked text present), don't intercept key
        // events for bindings — let them flow through to keyDown so the input
        // method can process them normally.
        if hasMarkedText() {
            return false
        }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])

        // Printable text without Command/Control should stay on the normal keyDown
        // path. AppKit can still route layout-dependent punctuation through
        // performKeyEquivalent first, and probing bindings here can misclassify
        // keys such as ABC-QWERTZ Shift+7 ("/") or Shift+- ("?") as shortcuts.
        if !flags.contains(.command),
           !flags.contains(.control),
           let text = textForKeyEvent(event),
           shouldSendText(text) {
            lastPerformKeyEvent = nil
            return false
        }

        // Check if this event matches a Ghostty keybinding.
        let bindingFlags: ghostty_binding_flags_e? = {
            var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
            let text = textForKeyEvent(event).flatMap { shouldSendText($0) ? $0 : nil } ?? ""
            var flags = ghostty_binding_flags_e(0)
            let isBinding = text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
            }
            return isBinding ? flags : nil
        }()

        if let bindingFlags {
            let isConsumed = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue) != 0
            let isAll = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_ALL.rawValue) != 0

            // If the binding is consumed and not meant for the menu, allow menu first.
            // Performable bindings (e.g. paste_from_clipboard on Cmd+V) also go through
            // the menu so Edit > Paste handles them; otherwise keyDown fires the clipboard
            // request twice (interpretKeyEvents + ghostty_surface_key) and the paste is
            // corrupted. If no menu item handles it, keyDown below performs it directly.
            if isConsumed && !isAll && keySequence.isEmpty && keyTables.isEmpty {
                if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
                    return true
                }
            }

            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass Ctrl+Return through verbatim (prevent context menu equivalent).
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"

        case "/":
            // Treat Ctrl+/ as Ctrl+_ to avoid the system beep.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else {
                return false
            }
            equivalent = "_"

        default:
            // Ignore synthetic events.
            if event.timestamp == 0 {
                return false
            }

            // Only handle command/control-modified keys here.
            if !event.modifierFlags.contains(.command) &&
                !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }

            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    // Cmd-modified keys produce no text, so `characters` is empty for
                    // combos like Cmd+Shift+K; use the key itself so Ghostty can encode it.
                    equivalent = event.charactersIgnoringModifiers ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )

        if let finalEvent {
            keyDown(with: finalEvent)
            return true
        }

        return false
    }

    override func keyDown(with event: NSEvent) {
        guard let surface = surface else {
            // This view is itself the terminal responder. Passing the event to NSView
            // while the surface is unavailable makes AppKit interpret Escape and other
            // control keys as unhandled commands (escape leak, alert beep).
            return
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt)
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        // Set up text accumulator for interpretKeyEvents
        keyTextAccumulator = []
        keyRequestedDeleteBackward = false
        defer { keyTextAccumulator = nil }

        // Track whether we had marked text (IME preedit) before this event,
        // so we can detect when composition ends.
        let markedTextBefore = markedText.length > 0

        // Capture the keyboard layout ID before interpretation so we can
        // detect if an IME changed it (e.g. toggling input methods).
        // We only check when not already in a preedit state.
        let keyboardIdBefore: String? = markedTextBefore ? nil : Self.currentKeyboardLayoutID

        // Let the input system handle the event (for IME, dead keys, etc.)
        interpretKeyEvents([translationEvent])

        // If the keyboard layout changed, an input method grabbed the event.
        // Sync preedit and return without sending the key to Ghostty.
        if let keyboardIdBefore, keyboardIdBefore != Self.currentKeyboardLayoutID {
            syncPreedit(clearIfNeeded: markedTextBefore)
            return
        }

        // Sync the preedit state with Ghostty so it can render the IME
        // composition overlay.
        syncPreedit(clearIfNeeded: markedTextBefore)

        // Build the key event
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        // Control and Command never contribute to text translation
        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

        // We're composing if we have preedit (the obvious case). But we're also
        // composing if we don't have preedit and we had marked text before,
        // because this input probably just reset the preedit state. It shouldn't
        // be encoded. Example: Japanese begin composing, then press backspace.
        // This should only cancel the composing state but not actually delete
        // the prior input characters (prior to the composing).
        keyEvent.composing = markedText.length > 0 || markedTextBefore

        let accumulatedText = keyTextAccumulator ?? []

        // Vietnamese Telex commits its preedit on Backspace, then asks for
        // deleteBackward:. Ghostty drops UTF-8 attached to a Backspace key, so
        // send the commit as typed text and replay the Backspace on its own.
        if keyRequestedDeleteBackward, !accumulatedText.isEmpty {
            for text in accumulatedText where shouldSendText(text) {
                sendCommittedText(text, surface: surface)
            }
            keyEvent.composing = false
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.text = nil
            _ = ghostty_surface_key(surface, keyEvent)
            return
        }

        // Use accumulated text from insertText (for IME), or compute text for key
        if !accumulatedText.isEmpty {
            // Accumulated text is the result of a composition, never composing.
            keyEvent.composing = false
            for text in accumulatedText {
                if shouldSendText(text) {
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        _ = ghostty_surface_key(surface, keyEvent)
                    }
                } else {
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = nil
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            }

            if shouldSendCommittedIMEConfirmKey(event: translationEvent, markedTextBefore: markedTextBefore) {
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = nil
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            // Get the appropriate text for this key event
            // For control characters, this returns the unmodified character
            // so Ghostty's KeyEncoder can handle ctrl encoding
            let suppressFallbackText =
                keyEvent.composing ||
                shouldSuppressShiftSpaceFallbackText(event: translationEvent, markedTextBefore: markedTextBefore)
            if let text = textForKeyEvent(translationEvent) {
                if shouldSendText(text), !suppressFallbackText {
                    let handled = text.withCString { ptr in
                        keyEvent.text = ptr
                        return ghostty_surface_key(surface, keyEvent)
                    }
                    if handled {
                        numpadIMECommitDeduplicator.recordFallback(
                            text: text,
                            event: event,
                            sourceId: Self.currentKeyboardLayoutID
                        )
                    }
                } else {
                    keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                    keyEvent.text = nil
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            } else {
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = nil
                _ = ghostty_surface_key(surface, keyEvent)
            }
        }
    }

    /// Send IME-committed text as a plain typed chunk, detached from the physical key.
    private func sendCommittedText(_ text: String, surface: ghostty_surface_t) {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = 0
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        text.withCString { ptr in
            keyEvent.text = ptr
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    /// Korean IME commits the syllable and executes on a single Return, but the commit
    /// swallows the Return itself. Japanese/Chinese IMEs use Return only to confirm the
    /// conversion, so the extra Return is limited to Korean input sources.
    private func shouldSendCommittedIMEConfirmKey(event: NSEvent, markedTextBefore: Bool) -> Bool {
        guard markedTextBefore, markedText.length == 0 else { return false }
        guard event.keyCode == 36 || event.keyCode == 76 else { return false }
        guard let sourceId = Self.currentKeyboardLayoutID else { return false }
        return sourceId.range(of: "korean", options: .caseInsensitive) != nil
    }

    /// If AppKit consumed Shift+Space for IME/input-source switching, interpretKeyEvents
    /// can return without insertText and without a detectable layout ID change.
    /// In that case we must not synthesize a literal space fallback.
    private func shouldSuppressShiftSpaceFallbackText(event: NSEvent, markedTextBefore: Bool) -> Bool {
        guard event.keyCode == 49 else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.shift] else { return false }
        guard !markedTextBefore, markedText.length == 0 else { return false }
        return true
    }

    override func keyUp(with event: NSEvent) {
        guard let surface = surface else {
            // Pair with the consumed key-down path above.
            return
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = ghostty_surface_key(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = surface else {
            // Modifier changes are terminal input too; don't hand them to AppKit.
            return
        }

        guard !hasMarkedText(),
              let action = Self.modifierAction(forFlagsChanged: event) else { return }

        // Build the event by hand: modifier-only events must not reach the AppKit
        // character APIs used for regular key input.
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = 0
        _ = ghostty_surface_key(surface, keyEvent)
    }

    /// `flagsChanged` fires for both modifier presses and releases. Reporting every
    /// edge as a press leaves Ghostty with a phantom held modifier until a later
    /// focus loss flushes release events into the PTY.
    private static func modifierAction(forFlagsChanged event: NSEvent) -> ghostty_input_action_e? {
        let flags = event.modifierFlags
        let rawFlags = flags.rawValue
        let modifierActive: Bool
        switch event.keyCode {
        case 0x39:
            modifierActive = flags.contains(.capsLock)
        case 0x38, 0x3C:
            modifierActive = flags.contains(.shift)
        case 0x3B, 0x3E:
            modifierActive = flags.contains(.control)
        case 0x3A, 0x3D:
            modifierActive = flags.contains(.option)
        case 0x37, 0x36:
            modifierActive = flags.contains(.command)
        default:
            return nil
        }

        guard modifierActive else { return GHOSTTY_ACTION_RELEASE }

        // The other side of the same modifier may still be held, so check the
        // device-dependent bit for right-side keys.
        let sidePressed: Bool
        switch event.keyCode {
        case 0x3C:
            sidePressed = rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0
        case 0x3E:
            sidePressed = rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0
        case 0x3D:
            sidePressed = rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0
        case 0x36:
            sidePressed = rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0
        default:
            sidePressed = true
        }

        return sidePressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if event.modifierFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if event.modifierFlags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if event.modifierFlags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if event.modifierFlags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Consumed mods are modifiers that were used for text translation.
    /// Control and Command never contribute to text translation, so they
    /// should be excluded from consumed_mods.
    private func consumedModsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        // Only include Shift and Option as potentially consumed
        // Control and Command are never consumed for text translation
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Get the characters for a key event with control character handling.
    /// When control is pressed, we get the character without the control modifier
    /// so Ghostty's KeyEncoder can apply its own control character encoding.
    private func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }

        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // If we have a single control character, return the character without
            // the control modifier so Ghostty's KeyEncoder can handle it.
            if isControlCharacterScalar(scalar) {
                if flags.contains(.control) {
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                }

                // Some AppKit key paths can report Shift+` as a bare ESC control
                // character even though the physical key should produce "~".
                if scalar.value == 0x1B,
                   flags == [.shift],
                   event.charactersIgnoringModifiers == "`" {
                    return "~"
                }
            }
            // Private Use Area characters (function keys) should not be sent
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return chars
    }

    /// Get the unshifted codepoint for the key event
    private func unshiftedCodepointFromEvent(_ event: NSEvent) -> UInt32 {
        guard let chars = event.characters(byApplyingModifiers: []),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    private func isControlCharacterScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    private func shouldSendText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text.count == 1, let scalar = text.unicodeScalars.first {
            return !isControlCharacterScalar(scalar)
        }
        return true
    }

    private func ghosttyKeyEvent(for event: NSEvent, surface: ghostty_surface_t) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt).
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)
        return keyEvent
    }

    func updateKeySequence(_ action: ghostty_action_key_sequence_s) {
        if action.active {
            keySequence.append(action.trigger)
        } else {
            keySequence.removeAll()
        }
    }

    func updateKeyTable(_ action: ghostty_action_key_table_s) {
        switch action.tag {
        case GHOSTTY_KEY_TABLE_ACTIVATE:
            let namePtr = action.value.activate.name
            let nameLen = Int(action.value.activate.len)
            if let namePtr, nameLen > 0 {
                let data = Data(bytes: namePtr, count: nameLen)
                if let name = String(data: data, encoding: .utf8) {
                    keyTables.append(name)
                }
            }
        case GHOSTTY_KEY_TABLE_DEACTIVATE:
            _ = keyTables.popLast()
        case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
            keyTables.removeAll()
        default:
            break
        }
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Only update the mouse position on the first click so a double-click
        // selection doesn't move the cursor.
        if event.clickCount == 1 {
            ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseUp(with: event)
            return
        }

        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let surface = surface else { return nil }
        if ghostty_surface_mouse_captured(surface) {
            return nil
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))

        let menu = NSMenu()
        if onTriggerFlash != nil {
            let flashItem = menu.addItem(withTitle: "Trigger Flash", action: #selector(triggerFlash(_:)), keyEquivalent: "")
            flashItem.target = self
            menu.addItem(.separator())
        }
        if ghostty_surface_has_selection(surface) {
            let item = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            item.target = self
        }
        let pasteItem = menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(.separator())
        let mermaidItem = menu.addItem(withTitle: "Render Mermaid Diagram", action: #selector(renderMermaid(_:)), keyEquivalent: "")
        mermaidItem.target = self
        return menu
    }

    @objc private func renderMermaid(_ sender: Any?) {
        MermaidPreviewController.renderFromFocusedSurface(terminalSurface)
    }

    @objc private func triggerFlash(_ sender: Any?) {
        onTriggerFlash?()
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface = surface else { return }
        if NSEvent.pressedMouseButtons != 0 {
            return
        }
        ghostty_surface_mouse_pos(surface, -1, -1, modsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }
        lastScrollEventTime = CACurrentMediaTime()
        Self.focusLog("scrollWheel: surface=\(terminalSurface?.id.uuidString ?? "nil") firstResponder=\(String(describing: window?.firstResponder))")
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }

        var mods: Int32 = 0
        if precision {
            mods |= 0b0000_0001
        }

        let momentum: Int32
        switch event.momentumPhase {
        case .began:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
        mods |= momentum << 1

        ghostty_surface_mouse_scroll(
            surface,
            x,
            y,
            ghostty_input_scroll_mods_t(mods)
        )
    }

    deinit {
        // Surface lifecycle is managed by TerminalSurface, not the view
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
        terminalSurface = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ],
            owner: self,
            userInfo: nil
        )

        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    private func windowDidChangeScreen(_ notification: Notification) {
        guard let window else { return }
        guard let object = notification.object as? NSWindow, window == object else { return }
        guard let screen = window.screen else { return }
        guard let surface = terminalSurface?.surface else { return }

        ghostty_surface_set_display_id(surface, screen.displayID ?? 0)

        // Don't replay viewDidChangeBackingProperties here: AppKit already delivers it
        // when the backing scale actually changes. Forcing a geometry recommit on every
        // display connect/disconnect clears the Metal surface for a frame (flash).
    }
}

private extension NSScreen {
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}

struct GhosttyScrollbar {
    let total: UInt64
    let offset: UInt64
    let len: UInt64

    init(c: ghostty_action_scrollbar_s) {
        total = c.total
        offset = c.offset
        len = c.len
    }
}

enum GhosttyNotificationKey {
    static let scrollbar = "ghostty.scrollbar"
    static let cellSize = "ghostty.cellSize"
    static let tabId = "ghostty.tabId"
    static let surfaceId = "ghostty.surfaceId"
    static let title = "ghostty.title"
}

extension Notification.Name {
    static let ghosttyDidUpdateScrollbar = Notification.Name("ghosttyDidUpdateScrollbar")
    static let ghosttyDidUpdateCellSize = Notification.Name("ghosttyDidUpdateCellSize")
    static let ghosttySearchFocus = Notification.Name("ghosttySearchFocus")
    static let ghosttyConfigDidReload = Notification.Name("ghosttyConfigDidReload")
}

// MARK: - Scroll View Wrapper (Ghostty-style scrollbar)

private final class GhosttyScrollView: NSScrollView {
    weak var surfaceView: GhosttyNSView?

    // Keep keyboard routing on the terminal surface; this wrapper is viewport plumbing.
    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        guard let surfaceView else {
            super.scrollWheel(with: event)
            return
        }

        // Route wheel gestures (e.g. over the padding) to the terminal surface so
        // Ghostty handles scrollback. Letting NSScrollView consume them moves the
        // wrapper viewport itself, which drifts the pane instead of scrolling.
        GhosttyNSView.focusLog("GhosttyScrollView.scrollWheel: surface scroll")
        if window?.firstResponder !== surfaceView {
            window?.makeFirstResponder(surfaceView)
        }
        surfaceView.scrollWheel(with: event)
    }
}

private final class GhosttyFlashOverlayView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class GhosttySurfaceScrollView: NSView {
    private let backgroundView: NSView
    private let scrollView: GhosttyScrollView
    private let documentView: NSView
    private let surfaceView: GhosttyNSView
    private let flashOverlayView: GhosttyFlashOverlayView
    private let flashLayer: CAShapeLayer
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    private var lastSentRow: Int?
    private var isActive = true
    private var focusWorkItem: DispatchWorkItem?
#if DEBUG
    private static var flashCounts: [UUID: Int] = [:]

    static func flashCount(for surfaceId: UUID) -> Int {
        flashCounts[surfaceId, default: 0]
    }

    static func resetFlashCounts() {
        flashCounts.removeAll()
    }

    private static func recordFlash(for surfaceId: UUID) {
        flashCounts[surfaceId, default: 0] += 1
    }
#endif

    init(surfaceView: GhosttyNSView) {
        self.surfaceView = surfaceView
        backgroundView = NSView(frame: .zero)
        scrollView = GhosttyScrollView()
        flashOverlayView = GhosttyFlashOverlayView(frame: .zero)
        flashLayer = CAShapeLayer()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.clipsToBounds = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.surfaceView = surfaceView

        documentView = NSView(frame: .zero)
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.documentView = documentView
        documentView.addSubview(surfaceView)

        super.init(frame: .zero)

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor =
            GhosttyApp.shared.defaultBackgroundColor
                .withAlphaComponent(GhosttyApp.shared.defaultBackgroundOpacity)
                .cgColor
        addSubview(backgroundView)
        addSubview(scrollView)
        flashOverlayView.wantsLayer = true
        flashOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        flashOverlayView.layer?.masksToBounds = false
        flashOverlayView.autoresizingMask = [.width, .height]
        flashLayer.fillColor = NSColor.clear.cgColor
        flashLayer.strokeColor = NSColor.systemBlue.cgColor
        flashLayer.lineWidth = 3
        flashLayer.lineJoin = .round
        flashLayer.lineCap = .round
        flashLayer.shadowColor = NSColor.systemBlue.cgColor
        flashLayer.shadowOpacity = 0.6
        flashLayer.shadowRadius = 6
        flashLayer.shadowOffset = .zero
        flashLayer.opacity = 0
        flashOverlayView.layer?.addSublayer(flashLayer)
        addSubview(flashOverlayView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.handleScrollChange()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = true
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = false
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.handleLiveScroll()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollbarUpdate(notification)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateCellSize,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            self?.synchronizeScrollView()
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        cancelFocusRequest()
    }

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    // Avoid stealing focus on scroll; focus is managed explicitly by the surface view.
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        backgroundView.frame = bounds
        scrollView.frame = bounds
        surfaceView.frame.size = scrollView.bounds.size
        documentView.frame.size.width = scrollView.bounds.width
        flashOverlayView.frame = bounds
        updateFlashPath()
        synchronizeScrollView()
        synchronizeSurfaceView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        guard let window else { return }
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateFocusForWindow()
            self?.requestFocus()
        })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateFocusForWindow()
        })
        updateFocusForWindow()
        if window.isKeyWindow { requestFocus() }
    }

    func attachSurface(_ terminalSurface: TerminalSurface) {
        surfaceView.attachSurface(terminalSurface)
    }

    func setFocusHandler(_ handler: (() -> Void)?) {
        surfaceView.onFocus = handler
    }

    func setTriggerFlashHandler(_ handler: (() -> Void)?) {
        surfaceView.onTriggerFlash = handler
    }

    func setBackgroundColor(_ color: NSColor) {
        guard let layer = backgroundView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color.cgColor
        CATransaction.commit()
    }

    func triggerFlash() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
#if DEBUG
            if let surfaceId = self.surfaceView.terminalSurface?.id {
                Self.recordFlash(for: surfaceId)
            }
#endif
            self.updateFlashPath()
            self.flashLayer.removeAllAnimations()
            self.flashLayer.opacity = 0
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0, 1, 0, 1, 0]
            animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            animation.duration = 0.9
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeIn),
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeIn)
            ]
            self.flashLayer.add(animation, forKey: "cter.flash")
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        updateFocusForWindow()
        if active {
            requestFocus()
        } else {
            cancelFocusRequest()
        }
    }

    func moveFocus(from previous: GhosttySurfaceScrollView? = nil, delay: TimeInterval? = nil) {
        let maxDelay: TimeInterval = 0.5
        guard (delay ?? 0) < maxDelay else { return }

        let nextDelay: TimeInterval = if let delay {
            delay * 2
        } else {
            0.05
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let window = self.window else {
                self.moveFocus(from: previous, delay: nextDelay)
                return
            }

            if let previous, previous !== self {
                _ = previous.surfaceView.resignFirstResponder()
            }

            window.makeFirstResponder(self.surfaceView)
        }

        let queue = DispatchQueue.main
        if let delay {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    func ensureFocus(for tabId: UUID, surfaceId: UUID, attempt: Int = 0) {
        let maxAttempts = 6
        guard attempt < maxAttempts else { return }
        guard let tabManager = AppDelegate.shared?.tabManager,
              tabManager.selectedTabId == tabId,
              tabManager.focusedSurfaceId(for: tabId) == surfaceId else { return }
        if surfaceView.terminalSurface?.searchState != nil {
            return
        }

        guard let window else {
            scheduleFocusRetry(for: tabId, surfaceId: surfaceId, attempt: attempt)
            return
        }

        guard window.isKeyWindow else {
            scheduleFocusRetry(for: tabId, surfaceId: surfaceId, attempt: attempt)
            return
        }

        if window.firstResponder === surfaceView {
            return
        }

        // Don't steal focus from a text field the user is editing (e.g. inline tab rename).
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            return
        }

        // Wait until the pane is visible and laid out before taking focus.
        guard isUsableForFocus else {
            scheduleFocusRetry(for: tabId, surfaceId: surfaceId, attempt: attempt)
            return
        }

        window.makeFirstResponder(surfaceView)

        if window.firstResponder !== surfaceView {
            scheduleFocusRetry(for: tabId, surfaceId: surfaceId, attempt: attempt)
        }
    }

    private func scheduleFocusRetry(for tabId: UUID, surfaceId: UUID, attempt: Int) {
        let delay = 0.05 * pow(2.0, Double(attempt))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.ensureFocus(for: tabId, surfaceId: surfaceId, attempt: attempt + 1)
        }
    }

    private func updateFocusForWindow() {
        let shouldFocus = isActive && (window?.isKeyWindow ?? false)
        surfaceView.desiredFocus = shouldFocus
        surfaceView.terminalSurface?.setFocus(shouldFocus)
    }

    private func requestFocus(delay: TimeInterval? = nil) {
        guard isActive else { return }
        if surfaceView.terminalSurface?.searchState != nil {
            return
        }
        let maxDelay: TimeInterval = 0.5
        guard (delay ?? 0) < maxDelay else { return }

        let nextDelay: TimeInterval = if let delay {
            delay * 2
        } else {
            0.05
        }

        cancelFocusRequest()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isActive else { return }
            if self.surfaceView.terminalSurface?.searchState != nil {
                return
            }
            guard let window = self.window else {
                self.requestFocus(delay: nextDelay)
                return
            }
            guard window.isKeyWindow else { return }

            if window.firstResponder === self.surfaceView {
                return
            }

            guard self.isUsableForFocus else {
                self.requestFocus(delay: nextDelay)
                return
            }

            if let responder = window.firstResponder as? NSView, responder !== self.surfaceView {
                _ = responder.resignFirstResponder()
            }

            window.makeFirstResponder(self.surfaceView)

            if window.firstResponder !== self.surfaceView {
                self.requestFocus(delay: nextDelay)
            }
        }

        let queue = DispatchQueue.main
        focusWorkItem = work
        if let delay {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    private var isUsableForFocus: Bool {
        !isHiddenOrHasHiddenAncestor &&
            bounds.width > 1 && bounds.height > 1 &&
            surfaceView.hasUsableFocusGeometry
    }

    func cancelFocusRequest() {
        focusWorkItem?.cancel()
        focusWorkItem = nil
    }

    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        surfaceView.frame.origin = visibleRect.origin
    }

    private func updateFlashPath() {
        let inset: CGFloat = 2
        let radius: CGFloat = 6
        let bounds = flashOverlayView.bounds
        flashLayer.frame = bounds
        guard bounds.width > inset * 2, bounds.height > inset * 2 else {
            flashLayer.path = nil
            return
        }
        let rect = bounds.insetBy(dx: inset, dy: inset)
        flashLayer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func synchronizeScrollView() {
        documentView.frame.size.height = documentHeight()

        if !isLiveScrolling {
            let cellHeight = surfaceView.cellSize.height
            if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
                let offsetY =
                    CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
                lastSentRow = Int(scrollbar.offset)
            }
        }

        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func handleScrollChange() {
        synchronizeSurfaceView()
    }

    private func handleLiveScroll() {
        let cellHeight = surfaceView.cellSize.height
        guard cellHeight > 0 else { return }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.frame.height
        let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height
        let row = Int(scrollOffset / cellHeight)

        guard row != lastSentRow else { return }
        lastSentRow = row
        _ = surfaceView.performBindingAction("scroll_to_row:\(row)")
    }

    private func handleScrollbarUpdate(_ notification: Notification) {
        guard let scrollbar = notification.userInfo?[GhosttyNotificationKey.scrollbar] as? GhosttyScrollbar else {
            return
        }
        surfaceView.scrollbar = scrollbar
        synchronizeScrollView()
    }

    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = surfaceView.cellSize.height
        if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
            let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
            let padding = contentHeight - (CGFloat(scrollbar.len) * cellHeight)
            return documentGridHeight + padding
        }
        return contentHeight
    }
}

// MARK: - Numpad IME commit dedup

/// Tracks raw numpad fallback sends that may be followed by a deferred IME commit
/// for the same key (e.g. Traditional Chinese IMEs during a full-to-half-width
/// transition). AppKit gives no token tying a late `insertText` back to its keyDown,
/// so this is a narrow timing heuristic: numpad digits only, input-method sources
/// only, one-shot matching, short expiry.
private struct NumpadIMECommitDeduplicator {
    private static let commitSuppressionWindow: TimeInterval = 0.25
    private static let maxPendingCommits = 8

    private struct PendingCommit {
        let text: String
        let keyCode: UInt16
        let sourceId: String?
        let timestamp: TimeInterval
    }

    private var pendingCommits: [PendingCommit] = []

    mutating func recordFallback(text: String, event: NSEvent, sourceId: String?) {
        let now = ProcessInfo.processInfo.systemUptime
        pruneExpiredCommits(now: now)

        guard normalizedNumpadFlags(event.modifierFlags) == [.numericPad],
              let sourceId, sourceId.localizedCaseInsensitiveContains("inputmethod"),
              text.allSatisfy(\.isNumber) else {
            return
        }

        pendingCommits.append(PendingCommit(text: text, keyCode: event.keyCode, sourceId: sourceId, timestamp: now))
        if pendingCommits.count > Self.maxPendingCommits {
            pendingCommits.removeFirst(pendingCommits.count - Self.maxPendingCommits)
        }
    }

    mutating func shouldSuppressCommit(
        _ text: String,
        currentEvent: NSEvent?,
        sourceId: String?,
        isExternalCommit: Bool,
        keyTextAccumulatorIsActive: Bool
    ) -> Bool {
        if isExternalCommit {
            pendingCommits.removeAll()
            return false
        }
        guard !keyTextAccumulatorIsActive else { return false }

        pruneExpiredCommits(now: ProcessInfo.processInfo.systemUptime)
        guard let index = pendingCommits.firstIndex(where: { $0.text == text && $0.sourceId == sourceId }) else {
            return false
        }

        let pendingCommit = pendingCommits.remove(at: index)
        if let currentEvent, currentEvent.type == .keyDown {
            return normalizedNumpadFlags(currentEvent.modifierFlags) == [.numericPad] &&
                currentEvent.keyCode == pendingCommit.keyCode
        }
        return true
    }

    private mutating func pruneExpiredCommits(now: TimeInterval) {
        pendingCommits.removeAll { now - $0.timestamp > Self.commitSuppressionWindow }
    }

    private func normalizedNumpadFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .capsLock])
    }
}

// MARK: - NSTextInputClient

extension GhosttyNSView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        if markedText.length > 0 {
            return markedSelectedRange
        }
        // Dictation and other text services need a real insertion point.
        return readSelectionSnapshot()?.range ?? NSRange(location: 0, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let incoming: NSAttributedString
        switch string {
        case let v as NSAttributedString:
            incoming = v
        case let v as String:
            incoming = NSAttributedString(string: v)
        default:
            return
        }

        // replacementRange is relative to the start of the current marked text.
        // Japanese IME replaces a subrange during conversion edits, including an
        // empty replacement for Backspace; keep the rest of the preedit buffer.
        if markedText.length > 0,
           replacementRange.location != NSNotFound,
           replacementRange.location <= markedText.length,
           replacementRange.length <= markedText.length - replacementRange.location {
            markedText.replaceCharacters(in: replacementRange, with: incoming)
        } else {
            markedText = NSMutableAttributedString(attributedString: incoming)
        }
        markedSelectedRange = Self.clampedMarkedSelection(selectedRange, markedLength: markedText.length)

        // If we're not in a keyDown event, sync preedit immediately.
        // This can happen due to external events like changing keyboard layouts
        // while composing.
        if keyTextAccumulator == nil {
            syncPreedit()
            invalidateTextInputCoordinates(selectionChanged: true)
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            markedSelectedRange = NSRange(location: 0, length: 0)
            syncPreedit()
            invalidateTextInputCoordinates(selectionChanged: true)
        }
    }

    private static func clampedMarkedSelection(_ range: NSRange, markedLength: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: markedLength, length: 0)
        }
        let location = min(max(range.location, 0), markedLength)
        let length = min(max(range.length, 0), markedLength - location)
        return NSRange(location: location, length: length)
    }

    /// String ID of the current keyboard input source.
    fileprivate static var currentKeyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let sourceIdPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(sourceIdPointer).takeUnretainedValue() as String
    }

    /// Sync the preedit state based on the markedText value to libghostty
    /// so it can render the IME composition overlay.
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface = surface else { return }

        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    // Subtract 1 for the null terminator
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            // If we had marked text before but don't now, we're no longer
            // in a preedit state so we can clear it.
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.length > 0,
              let snapshot = readSelectionSnapshot() else { return nil }
        actualRange?.pointee = snapshot.range
        return NSAttributedString(string: snapshot.string)
    }

    func characterIndex(for point: NSPoint) -> Int {
        return selectedRange().location
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window = self.window else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        // Use Ghostty's IME point API for accurate cursor position.
        var x: Double = 0
        var y: Double = 0
        var w: Double = cellSize.width
        var h: Double = cellSize.height
        if range.length > 0,
           range != selectedRange(),
           let snapshot = readSelectionSnapshot() {
            // A text service asking about the selection, not the insertion point.
            x = snapshot.topLeft.x - 2
            y = snapshot.topLeft.y + 2
        } else if let surface = surface {
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        }

        if range.length == 0, w > 0 {
            // Dictation expects a caret rect for insertion points rather than a box.
            w = 0
        }

        // Ghostty coordinates are top-left origin; AppKit expects bottom-left.
        let viewRect = NSRect(
            x: x,
            y: frame.size.height - y,
            width: w,
            height: max(h, cellSize.height)
        )
        let winRect = convert(viewRect, to: nil)
        return window.convertToScreen(winRect)
    }

    func attributedString() -> NSAttributedString {
        if markedText.length > 0 {
            return NSAttributedString(attributedString: markedText)
        }
        if let snapshot = readSelectionSnapshot(), !snapshot.string.isEmpty {
            return NSAttributedString(string: snapshot.string)
        }
        return NSAttributedString(string: "")
    }

    func windowLevel() -> Int {
        Int(window?.level.rawValue ?? NSWindow.Level.normal.rawValue)
    }

    @available(macOS 14.0, *)
    var unionRectInVisibleSelectedRange: NSRect {
        firstRect(forCharacterRange: selectedRange(), actualRange: nil)
    }

    @available(macOS 14.0, *)
    var documentVisibleRect: NSRect {
        let windowRect = convert(visibleRect, to: nil)
        guard let window else { return windowRect }
        return window.convertToScreen(windowRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // Get the string value
        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        // Clear marked text since we're inserting
        unmarkText()

        // Some IME/input-method paths call insertText with an empty payload to
        // flush state. There is no terminal text to send in that case.
        guard !chars.isEmpty else { return }

        // A deferred IME commit can replay a numpad digit keyDown already sent.
        if numpadIMECommitDeduplicator.shouldSuppressCommit(
            chars,
            currentEvent: NSApp.currentEvent,
            sourceId: Self.currentKeyboardLayoutID,
            isExternalCommit: externalCommittedTextDepth > 0,
            keyTextAccumulatorIsActive: keyTextAccumulator != nil
        ) {
            return
        }

        // If we have an accumulator, we're in a keyDown event - accumulate the text
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        // Text committed without a key event comes from dictation or accessibility
        // tools, some of which prepend escape/control sequences.
        let committed = NSApp.currentEvent == nil
            ? Self.sanitizeExternalCommittedText(chars)
            : chars
        guard !committed.isEmpty else { return }

        // Committed text goes through the paste-like text path, not key encoding.
        if let surface = surface, let data = committed.data(using: .utf8), !data.isEmpty {
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                ghostty_surface_text(surface, baseAddress, UInt(rawBuffer.count))
            }
        }
    }

    /// Strip leading escape/control sequences that some external text tools
    /// inject before plain text, so they can't leak into the PTY as literals.
    static func sanitizeExternalCommittedText(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B {
                index = consumeLeadingEscapeSequence(in: bytes, from: index)
            } else if byte == 0x9B {
                index = consumeLeadingCSISequence(in: bytes, from: index + 1)
            } else if byte < 0x20 || byte == 0x7F {
                index += 1
            } else {
                break
            }
        }

        if index == 0 { return text }
        guard index < bytes.count else { return "" }
        return String(decoding: bytes[index...], as: UTF8.self)
    }

    private static func consumeLeadingEscapeSequence(in bytes: [UInt8], from start: Int) -> Int {
        let next = start + 1
        guard next < bytes.count else { return bytes.count }

        switch bytes[next] {
        case 0x5B:
            // CSI: ESC [ ... final
            return consumeLeadingCSISequence(in: bytes, from: next + 1)
        case 0x4F:
            // SS3: ESC O final
            return min(bytes.count, next + 2)
        case 0x50, 0x5D, 0x5E, 0x5F:
            // DCS/OSC/PM/APC: consume until BEL/ST or EOF.
            return consumeLeadingEscapedStringSequence(in: bytes, from: next + 1)
        default:
            // Single-character escape.
            return min(bytes.count, next + 1)
        }
    }

    private static func consumeLeadingCSISequence(in bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if (0x20...0x3F).contains(byte) {
                index += 1
                continue
            }
            if (0x40...0x7E).contains(byte) {
                return index + 1
            }
            break
        }
        return index
    }

    private static func consumeLeadingEscapedStringSequence(in bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x07 {
                return index + 1
            }
            if byte == 0x1B {
                let next = index + 1
                if next < bytes.count, bytes[next] == 0x5C {
                    return next + 1
                }
                return index
            }
            if byte < 0x20 || byte == 0x7F {
                return index + 1
            }
            index += 1
        }
        return bytes.count
    }
}

// MARK: - SwiftUI Wrapper

struct GhosttyTerminalView: NSViewRepresentable {
    let terminalSurface: TerminalSurface
    var isActive: Bool = true
    var isVisible: Bool = true
    var onFocus: ((UUID) -> Void)? = nil
    var onTriggerFlash: (() -> Void)? = nil

    func makeNSView(context: Context) -> GhosttySurfaceScrollView {
        let view = terminalSurface.hostedView
        terminalSurface.setVisible(isVisible)
        view.attachSurface(terminalSurface)
        view.setActive(isActive)
        view.setFocusHandler { onFocus?(terminalSurface.id) }
        view.setTriggerFlashHandler(onTriggerFlash)
        return view
    }

    func updateNSView(_ nsView: GhosttySurfaceScrollView, context: Context) {
        terminalSurface.setVisible(isVisible)
        nsView.attachSurface(terminalSurface)
        nsView.setActive(isActive)
        nsView.setFocusHandler { onFocus?(terminalSurface.id) }
        nsView.setTriggerFlashHandler(onTriggerFlash)
    }
}
