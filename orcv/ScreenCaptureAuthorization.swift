import CoreGraphics

enum ScreenCaptureAuthorization {
    static func requestIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }
}
