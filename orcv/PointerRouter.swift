import AppKit
import CoreGraphics
import Foundation

final class PointerRouter {
    func teleportInto(workspace: Workspace, pointInTile: CGPoint, tileFrameInWindow: CGRect) {
        guard tileFrameInWindow.width > 0, tileFrameInWindow.height > 0 else { return }

        let displayBounds = CGDisplayBounds(workspace.displayID)
        let tileRect = CGRect(origin: .zero, size: tileFrameInWindow.size)
        guard let normalized = PointerMath.normalizedPoint(for: pointInTile, in: tileRect, sourceYFlipped: false),
              let destination = PointerMath.denormalizedPoint(from: normalized, in: displayBounds, destinationYFlipped: true) else { return }
        CGWarpMouseCursorPosition(destination)
    }

    func teleportBack(fromDisplayID displayID: CGDirectDisplayID, toTileScreenFrame tileScreenFrame: CGRect) {
        guard let currentMouseQuartz = CGEvent(source: nil)?.location else { return }
        let hitDisplays = displayIDs(at: currentMouseQuartz)
        guard hitDisplays.contains(displayID) else { return }
        let displayBounds = CGDisplayBounds(displayID)
        guard let yAxisSum = currentQuartzAppKitYAxisSum() else { return }
        let tileScreenFrameQuartz = appKitToQuartz(tileScreenFrame, yAxisSum: yAxisSum)
        guard displayBounds.width > 0, displayBounds.height > 0,
              tileScreenFrameQuartz.width > 0,
              tileScreenFrameQuartz.height > 0 else { return }
        guard displayBounds.contains(currentMouseQuartz) else { return }
        guard let normalized = PointerMath.normalizedPoint(for: currentMouseQuartz, in: displayBounds, sourceYFlipped: true),
              let destination = PointerMath.denormalizedPoint(from: normalized, in: tileScreenFrameQuartz, destinationYFlipped: true) else { return }

        CGWarpMouseCursorPosition(destination)
    }

    func currentMouseMapsIntoTile(fromDisplayID displayID: CGDirectDisplayID, toTileScreenFrame tileScreenFrame: CGRect) -> Bool {
        guard let currentMouseQuartz = CGEvent(source: nil)?.location else { return false }
        let hitDisplays = displayIDs(at: currentMouseQuartz)
        guard hitDisplays.contains(displayID) else { return false }
        let displayBounds = CGDisplayBounds(displayID)
        guard let yAxisSum = currentQuartzAppKitYAxisSum() else { return false }
        let tileScreenFrameQuartz = appKitToQuartz(tileScreenFrame, yAxisSum: yAxisSum)
        guard displayBounds.width > 0, displayBounds.height > 0,
              tileScreenFrameQuartz.width > 0,
              tileScreenFrameQuartz.height > 0 else {
            return false
        }
        guard displayBounds.contains(currentMouseQuartz) else { return false }
        guard let normalized = PointerMath.normalizedPoint(for: currentMouseQuartz, in: displayBounds, sourceYFlipped: true),
              let mappedPoint = PointerMath.denormalizedPoint(from: normalized, in: tileScreenFrameQuartz, destinationYFlipped: true) else {
            return false
        }

        return tileScreenFrameQuartz.insetBy(dx: -1.0, dy: -1.0).contains(mappedPoint)
    }

    func teleportToDisplay(displayID: CGDirectDisplayID, normalized: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        let displayBounds = CGDisplayBounds(displayID)
        guard let destination = PointerMath.denormalizedPoint(
            from: normalized,
            in: displayBounds,
            destinationYFlipped: true
        ) else {
            return
        }
        CGWarpMouseCursorPosition(destination)
    }

    private func displayIDs(at point: CGPoint) -> [CGDirectDisplayID] {
        DisplayQuery.displayIDs(at: point)
    }

    private func currentQuartzAppKitYAxisSum() -> CGFloat? {
        guard let quartz = CGEvent(source: nil)?.location else { return nil }
        let appKit = NSEvent.mouseLocation
        return quartz.y + appKit.y
    }

    private func appKitToQuartz(_ rect: CGRect, yAxisSum: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: yAxisSum - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
