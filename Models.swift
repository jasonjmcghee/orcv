import CoreGraphics
import Foundation

enum WorkspaceKind {
    case physical
    case virtual
}

enum WorkspaceLayoutMode: String {
    case tile
    case canvas
}

struct DisplayDescriptor {
    let displayID: CGDirectDisplayID
    let title: String
    let pixelSize: CGSize
    let kind: WorkspaceKind
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
