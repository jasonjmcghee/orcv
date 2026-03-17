import Foundation

struct PersistedWorkspaceState: Codable {
    struct CameraBookmark: Codable {
        var magnification: Double
        var offsetX: Double
        var offsetY: Double
        var windowX: Double?
        var windowY: Double?
        var windowWidth: Double?
        var windowHeight: Double?
        var referenceTileSerial: UInt32?
        var referenceTileIndex: Int?
        var tileOffsetX: Double?
        var tileOffsetY: Double?
        var seamlessMode: Bool?
    }

    struct WorkspaceEntry: Codable {
        var title: String
        var pixelWidth: Int
        var pixelHeight: Int
        var tileWidth: Double
        var tileHeight: Double
        var displaySerial: UInt32?
        var canvasX: Double?
        var canvasY: Double?
    }

    var version: Int
    var nextVirtualIndex: Int
    var focusedIndex: Int?
    var focusedDisplaySerial: UInt32?
    var dynamicLayoutColumns: Int?
    var layoutModeRawValue: String?
    var canvasMagnification: Double?
    var canvasOffsetX: Double?
    var canvasOffsetY: Double?
    var windowX: Double?
    var windowY: Double?
    var windowWidth: Double?
    var windowHeight: Double?
    var windowedRestoreX: Double?
    var windowedRestoreY: Double?
    var windowedRestoreWidth: Double?
    var windowedRestoreHeight: Double?
    var windowedRestoreCanvasMagnification: Double?
    var windowedRestoreCanvasOffsetX: Double?
    var windowedRestoreCanvasOffsetY: Double?
    var canvasSavepoints: [String: CameraBookmark]?
    var arrangePadding: Double?
    var autoArrangeModeRawValue: String?
    var sharpCorners: Bool?
    var seamlessMode: Bool?
    var requireHoldingMoveShortcut: Bool?
    var limitFPS: Double?
    var unlockFPSIfInteracting: Bool?
    var unlockFPSIfLargerThanPercent: Bool?
    var unlockFPSLargerThanPercentThreshold: Double?
    var workspaces: [WorkspaceEntry]
}

final class WorkspaceStateStore {
    private let queue = DispatchQueue(label: "today.jason.orcv.state-store")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileURL: URL
    private var pendingWrite: DispatchWorkItem?

    init(bundleIdentifier: String) {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let folder = appSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
        self.fileURL = folder.appendingPathComponent("workspace_state.json", isDirectory: false)

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> PersistedWorkspaceState? {
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(PersistedWorkspaceState.self, from: data)
        } catch {
            return nil
        }
    }

    func scheduleSave(_ state: PersistedWorkspaceState, debounce: TimeInterval = 0.35) {
        queue.async {
            self.pendingWrite?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.write(state)
            }
            self.pendingWrite = work
            self.queue.asyncAfter(deadline: .now() + debounce, execute: work)
        }
    }

    func flushNow(_ state: PersistedWorkspaceState) {
        queue.sync {
            pendingWrite?.cancel()
            pendingWrite = nil
            write(state)
        }
    }

    private func write(_ state: PersistedWorkspaceState) {
        do {
            let folder = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }
}
