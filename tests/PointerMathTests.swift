import CoreGraphics
import Foundation

func assertClose(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.0001, _ message: String) {
    if abs(lhs - rhs) > tolerance {
        fputs("FAIL: \(message) (\(lhs) vs \(rhs))\n", stderr)
        exit(1)
    }
}

func assertPointClose(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat = 0.0001, _ message: String) {
    assertClose(lhs.x, rhs.x, tolerance: tolerance, "\(message) [x]")
    assertClose(lhs.y, rhs.y, tolerance: tolerance, "\(message) [y]")
}

func testRoundTripNoFlip() {
    let tile = CGRect(x: 100, y: 200, width: 360, height: 202.5)
    let display = CGRect(x: 2560, y: -120, width: 1536, height: 960)
    let original = CGPoint(x: 320, y: 280)

    guard let intoDisplay = PointerMath.mapPoint(
        original,
        from: tile,
        to: display,
        sourceYFlipped: false,
        destinationYFlipped: false
    ),
    let backToTile = PointerMath.mapPoint(
        intoDisplay,
        from: display,
        to: tile,
        sourceYFlipped: false,
        destinationYFlipped: false
    ) else {
        fputs("FAIL: testRoundTripNoFlip could not map point\n", stderr)
        exit(1)
    }

    assertPointClose(backToTile, original, "round-trip should be identity without Y flip")
}

func testRoundTripWithOppositeYOrientation() {
    let tile = CGRect(x: 42, y: 88, width: 512, height: 320)
    let display = CGRect(x: -1728, y: 0, width: 1920, height: 1080)
    let original = CGPoint(x: 300, y: 300)

    // AppKit-style source (Y up) -> Quartz-style destination (Y down), then back.
    guard let intoDisplay = PointerMath.mapPoint(
        original,
        from: tile,
        to: display,
        sourceYFlipped: false,
        destinationYFlipped: true
    ),
    let backToTile = PointerMath.mapPoint(
        intoDisplay,
        from: display,
        to: tile,
        sourceYFlipped: true,
        destinationYFlipped: false
    ) else {
        fputs("FAIL: testRoundTripWithOppositeYOrientation could not map point\n", stderr)
        exit(1)
    }

    assertPointClose(backToTile, original, "round-trip should be identity across opposite Y orientations")
}

func testClamping() {
    let source = CGRect(x: 10, y: 10, width: 100, height: 80)
    let destination = CGRect(x: 1000, y: 1000, width: 400, height: 300)
    let outside = CGPoint(x: -999, y: 9999)

    guard let mapped = PointerMath.mapPoint(
        outside,
        from: source,
        to: destination,
        sourceYFlipped: false,
        destinationYFlipped: false
    ) else {
        fputs("FAIL: testClamping could not map point\n", stderr)
        exit(1)
    }

    assertPointClose(mapped, CGPoint(x: destination.minX, y: destination.maxY), "outside point should clamp to destination bounds")
}

func testRetinaIndependentNormalization() {
    let tile = CGRect(x: 0, y: 0, width: 360, height: 202.5)
    let displayPoints = CGRect(x: 0, y: 0, width: 960, height: 540)
    let displayPixelsEquivalent = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    let click = CGPoint(x: 90, y: 50.625) // exactly (0.25, 0.25)

    guard let toPoints = PointerMath.mapPoint(
        click,
        from: tile,
        to: displayPoints,
        sourceYFlipped: false,
        destinationYFlipped: false
    ),
    let toPixels = PointerMath.mapPoint(
        click,
        from: tile,
        to: displayPixelsEquivalent,
        sourceYFlipped: false,
        destinationYFlipped: false
    ) else {
        fputs("FAIL: testRetinaIndependentNormalization could not map point\n", stderr)
        exit(1)
    }

    assertPointClose(toPoints, CGPoint(x: 240, y: 135), "point-space mapping should preserve normalized position")
    assertPointClose(toPixels, CGPoint(x: 480, y: 270), "pixel-space mapping should preserve normalized position")
}

func runAllTests() {
    testRoundTripNoFlip()
    testRoundTripWithOppositeYOrientation()
    testClamping()
    testRetinaIndependentNormalization()
    print("PointerMath tests passed")
}

@main
struct PointerMathTestRunner {
    static func main() {
        runAllTests()
    }
}
