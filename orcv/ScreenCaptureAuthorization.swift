import AppKit
import ApplicationServices
import CoreGraphics

enum ScreenCaptureAuthorization {
    static func hasAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestIfNeeded() -> Bool {
        if hasAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        openPrivacyPane(anchor: "Privacy_ScreenCapture")
    }
}

enum AccessibilityAuthorization {
    static func hasAccess() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestIfNeeded() -> Bool {
        if hasAccess() {
            return true
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }
}

private func openPrivacyPane(anchor: String) {
    let urls = [
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"),
        URL(string: "x-apple.systempreferences:com.apple.preference.security"),
    ].compactMap { $0 }

    for url in urls where NSWorkspace.shared.open(url) {
        return
    }
}
