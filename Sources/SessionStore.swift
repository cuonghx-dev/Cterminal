import Foundation

/// Serializable snapshot of the open workspace tabs, their split layouts and pane tabs.
/// Written periodically so the layout survives crashes and force quits, then used to
/// rebuild the tabs on the next launch. Scrollback and running processes are not kept:
/// each restored terminal starts a fresh shell in its saved directory.
struct SessionSnapshot: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = SessionSnapshot.currentVersion
    var selectedTabIndex: Int?
    var tabs: [TabSnapshot]

    struct TabSnapshot: Codable, Equatable {
        var customTitle: String?
        var isPinned: Bool
        var currentDirectory: String
        /// Index of the focused surface in split order, then pane-tab order.
        var focusedSurfaceIndex: Int?
        var layout: NodeSnapshot
    }

    indirect enum NodeSnapshot: Codable, Equatable {
        case pane(PaneSnapshot)
        case split(SplitSnapshot)
    }

    struct SplitSnapshot: Codable, Equatable {
        enum Direction: String, Codable {
            case horizontal
            case vertical
        }

        var direction: Direction
        var ratio: Double
        var left: NodeSnapshot
        var right: NodeSnapshot
    }

    struct PaneSnapshot: Codable, Equatable {
        var surfaces: [SurfaceSnapshot]
        var selectedIndex: Int
    }

    struct SurfaceSnapshot: Codable, Equatable {
        var directory: String?
        var title: String?
    }
}

/// Reads and writes `session.json` in the app's Application Support folder. Tagged debug
/// builds have their own bundle identifier, so each gets its own file.
final class SessionStore {
    static let restoreSettingKey = "restoreSessionOnLaunch"
    static let skipRestoreEnvKey = "CTER_SKIP_SESSION_RESTORE"

    private let fileURL: URL
    private var lastWrittenData: Data?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? SessionStore.defaultFileURL()
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let folder = Bundle.main.bundleIdentifier ?? "cter"
        return base.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("session.json", isDirectory: false)
    }

    /// True unless the user turned restore off in Settings or the launch env opts out.
    static var isRestoreEnabled: Bool {
        if let value = ProcessInfo.processInfo.environment[skipRestoreEnvKey], value == "1" || value.lowercased() == "true" {
            return false
        }
        return UserDefaults.standard.object(forKey: restoreSettingKey) as? Bool ?? true
    }

    /// Loads the saved snapshot. An unreadable or incompatible file is moved aside to
    /// `session.json.bak` so it never blocks launch.
    func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)
            guard snapshot.version == SessionSnapshot.currentVersion, !snapshot.tabs.isEmpty else {
                NSLog("Session: ignoring snapshot version=%d tabs=%d", snapshot.version, snapshot.tabs.count)
                moveAside()
                return nil
            }
            lastWrittenData = data
            return snapshot
        } catch {
            NSLog("Session: failed to decode %@: %@", fileURL.path, String(describing: error))
            moveAside()
            return nil
        }
    }

    /// Writes the snapshot atomically (temp file + rename), skipping unchanged content.
    func save(_ snapshot: SessionSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot), data != lastWrittenData else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            lastWrittenData = data
        } catch {
            NSLog("Session: failed to write %@: %@", fileURL.path, String(describing: error))
        }
    }

    private func moveAside() {
        let backupURL = fileURL.appendingPathExtension("bak")
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: backupURL)
        try? fileManager.moveItem(at: fileURL, to: backupURL)
    }
}

// MARK: - Capture

extension Tab {
    func sessionSnapshot() -> SessionSnapshot.TabSnapshot? {
        guard let root = splitTree.root else { return nil }
        let surfaceIds = allSurfaces.map(\.id)
        return SessionSnapshot.TabSnapshot(
            customTitle: customTitle,
            isPinned: isPinned,
            currentDirectory: currentDirectory,
            focusedSurfaceIndex: focusedSurfaceId.flatMap { surfaceIds.firstIndex(of: $0) },
            layout: sessionNode(root)
        )
    }

    private func sessionNode(_ node: SplitTree<TerminalPane>.Node) -> SessionSnapshot.NodeSnapshot {
        switch node {
        case .leaf(let pane):
            let surfaces = pane.surfaces.map { surface in
                SessionSnapshot.SurfaceSnapshot(
                    directory: surfaceDirectories[surface.id],
                    title: surfaceTitles[surface.id]
                )
            }
            let selectedIndex = pane.surfaces.firstIndex(where: { $0.id == pane.selectedSurfaceId }) ?? 0
            return .pane(SessionSnapshot.PaneSnapshot(surfaces: surfaces, selectedIndex: selectedIndex))
        case .split(let split):
            return .split(SessionSnapshot.SplitSnapshot(
                direction: split.direction == .horizontal ? .horizontal : .vertical,
                ratio: split.ratio,
                left: sessionNode(split.left),
                right: sessionNode(split.right)
            ))
        }
    }
}

extension TabManager {
    func sessionSnapshot() -> SessionSnapshot {
        let captured = tabs.compactMap { tab in tab.sessionSnapshot().map { (tab.id, $0) } }
        return SessionSnapshot(
            selectedTabIndex: captured.firstIndex(where: { $0.0 == selectedTabId }),
            tabs: captured.map(\.1)
        )
    }
}

// MARK: - Restore

extension SessionSnapshot {
    /// Returns `directory` if it still exists as a folder, otherwise nil.
    static func existingDirectory(_ directory: String?) -> String? {
        guard let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return trimmed
    }
}
