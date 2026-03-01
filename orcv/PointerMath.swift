import CoreGraphics
import Foundation

enum PointerMath {
    static func clamp01(_ value: CGFloat) -> CGFloat {
        max(0.0, min(1.0, value))
    }

    static func normalizedPoint(for point: CGPoint, in rect: CGRect, sourceYFlipped: Bool = false) -> CGPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }

        let rx = clamp01((point.x - rect.minX) / rect.width)
        let rawY = clamp01((point.y - rect.minY) / rect.height)
        let ry = sourceYFlipped ? (1.0 - rawY) : rawY
        return CGPoint(x: rx, y: ry)
    }

    static func denormalizedPoint(from normalized: CGPoint, in rect: CGRect, destinationYFlipped: Bool = false) -> CGPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }

        let rx = clamp01(normalized.x)
        let ry = clamp01(normalized.y)
        let mappedY = destinationYFlipped ? (1.0 - ry) : ry

        return CGPoint(
            x: rect.minX + rect.width * rx,
            y: rect.minY + rect.height * mappedY
        )
    }

    static func mapPoint(
        _ point: CGPoint,
        from source: CGRect,
        to destination: CGRect,
        sourceYFlipped: Bool = false,
        destinationYFlipped: Bool = false
    ) -> CGPoint? {
        guard let normalized = normalizedPoint(for: point, in: source, sourceYFlipped: sourceYFlipped) else { return nil }
        return denormalizedPoint(from: normalized, in: destination, destinationYFlipped: destinationYFlipped)
    }
}
