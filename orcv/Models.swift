import CoreGraphics
import Foundation

enum WorkspaceKind {
    case physical
    case virtual
}

enum WorkspaceLayoutMode: String {
    case canvas
}

struct DisplayDescriptor {
    let displayID: CGDirectDisplayID
    let title: String
    let pixelSize: CGSize
    let kind: WorkspaceKind
    let maxFPS: Double

    init(
        displayID: CGDirectDisplayID,
        title: String,
        pixelSize: CGSize,
        kind: WorkspaceKind,
        maxFPS: Double = 60.0
    ) {
        self.displayID = displayID
        self.title = title
        self.pixelSize = pixelSize
        self.kind = kind
        self.maxFPS = maxFPS
    }
}

struct Workspace {
    let id: UUID
    let displayID: CGDirectDisplayID
    var title: String
    var kind: WorkspaceKind
    var displayPixelSize: CGSize
    var tileSize: CGSize
    var canvasOrigin: CGPoint?
}

enum DisplayQuery {
    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return []
        }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &ids, &displayCount) == .success else {
            return []
        }
        return Array(ids.prefix(Int(displayCount)))
    }

    static func displayIDs(at point: CGPoint) -> [CGDirectDisplayID] {
        let onlineDisplayIDs = onlineDisplayIDs()
        guard !onlineDisplayIDs.isEmpty else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: onlineDisplayIDs.count)
        var count: UInt32 = 0
        let result = CGGetDisplaysWithPoint(point, UInt32(onlineDisplayIDs.count), &ids, &count)
        guard result == .success, count > 0 else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}

enum TileGeometry {
    static let defaultTileWidth: CGFloat = 360.0

    static func defaultTileSize(pixelSize: CGSize) -> CGSize {
        normalizedSizeFromWidth(pixelSize: pixelSize, targetWidth: defaultTileWidth)
    }

    static func normalizedSizeFromWidth(pixelSize: CGSize, targetWidth: CGFloat) -> CGSize {
        let ratio = aspectRatio(for: pixelSize)
        let width = (targetWidth.isFinite && targetWidth > 1.0) ? targetWidth : defaultTileWidth
        return CGSize(width: width, height: width / ratio)
    }

    static func normalizedSize(pixelSize: CGSize, targetHeight: CGFloat) -> CGSize {
        let ratio = aspectRatio(for: pixelSize)
        let height = (targetHeight.isFinite && targetHeight > 1.0) ? targetHeight : (defaultTileWidth / ratio)
        return CGSize(width: height * ratio, height: height)
    }

    static func aspectRatio(for pixelSize: CGSize) -> CGFloat {
        guard pixelSize.width.isFinite, pixelSize.height.isFinite, pixelSize.width > 1.0, pixelSize.height > 1.0 else {
            return 16.0 / 9.0
        }
        return max(0.1, pixelSize.width / pixelSize.height)
    }
}
