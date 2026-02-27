import CoreGraphics
import Foundation
import IOSurface

enum ReferenceSource: Hashable {
    case display(CGDirectDisplayID)
}

struct ReferenceRegion: Hashable {
    static let fullDisplay = ReferenceRegion(normalizedTopLeftRect: CGRect(x: 0, y: 0, width: 1, height: 1))

    let normalizedTopLeftRect: CGRect

    init(normalizedTopLeftRect: CGRect) {
        self.normalizedTopLeftRect = ReferenceRegion.clamp(normalizedTopLeftRect)
    }

    private static func clamp(_ rect: CGRect) -> CGRect {
        let x = max(0, min(1, rect.origin.x.isFinite ? rect.origin.x : 0))
        let y = max(0, min(1, rect.origin.y.isFinite ? rect.origin.y : 0))
        let width = max(0.0001, min(1 - x, rect.size.width.isFinite ? rect.size.width : 1))
        let height = max(0.0001, min(1 - y, rect.size.height.isFinite ? rect.size.height : 1))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // CALayer.contentsRect uses bottom-left origin; references use top-left.
    var layerContentsRect: CGRect {
        CGRect(
            x: normalizedTopLeftRect.origin.x,
            y: 1 - normalizedTopLeftRect.origin.y - normalizedTopLeftRect.height,
            width: normalizedTopLeftRect.width,
            height: normalizedTopLeftRect.height
        )
    }
}

struct SurfaceReference: Hashable {
    let source: ReferenceSource
    let region: ReferenceRegion

    init(source: ReferenceSource, region: ReferenceRegion = .fullDisplay) {
        self.source = source
        self.region = region
    }

    init(displayID: CGDirectDisplayID, region: ReferenceRegion = .fullDisplay) {
        self.init(source: .display(displayID), region: region)
    }
}

final class ReferenceSurfaceResolver {
    private let displaySurfaceProvider: (CGDirectDisplayID) -> IOSurface?

    init(displaySurfaceProvider: @escaping (CGDirectDisplayID) -> IOSurface?) {
        self.displaySurfaceProvider = displaySurfaceProvider
    }

    func surface(for reference: SurfaceReference) -> IOSurface? {
        switch reference.source {
        case .display(let displayID):
            return displaySurfaceProvider(displayID)
        }
    }
}
