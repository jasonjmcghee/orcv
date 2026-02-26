import AppKit
import CoreGraphics
import Foundation
import IOSurface
import QuartzCore

final class WorkspacePreviewWindowController: NSWindowController, NSWindowDelegate {
    private let previewView: DisplaySurfacePreviewView
    private var activeDisplayID: CGDirectDisplayID?
    private var previousPresentationOptions: NSApplication.PresentationOptions?
    private var previousWindowLevel: NSWindow.Level?
    private var previousCollectionBehavior: NSWindow.CollectionBehavior?

    init(surfaceProvider: @escaping (CGDirectDisplayID) -> IOSurface?) {
        previewView = DisplaySurfacePreviewView(surfaceProvider: surfaceProvider)

        let window = ImmersivePreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.title = "Display Preview"
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = previewView

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    var isPresenting: Bool {
        activeDisplayID != nil
    }

    var presentedDisplayID: CGDirectDisplayID? {
        activeDisplayID
    }

    func presentImmersive(for workspace: Workspace) {
        guard let window else { return }

        activeDisplayID = workspace.displayID
        previewView.displayID = workspace.displayID
        window.title = workspace.title

        if let targetScreen = NSScreen.main ?? window.screen ?? NSScreen.screens.first {
            window.setFrame(targetScreen.frame, display: true)
            let scale = targetScreen.backingScaleFactor
            let frame = targetScreen.frame
            let targetPixels = CGSize(width: frame.width * scale, height: frame.height * scale)
            NSLog(
                "ImmersivePreview geometry screenPoints=(%.1f x %.1f) scale=%.3f targetPixels=(%.1f x %.1f) workspacePixels=(%.1f x %.1f)",
                frame.width,
                frame.height,
                scale,
                targetPixels.width,
                targetPixels.height,
                workspace.displayPixelSize.width,
                workspace.displayPixelSize.height
            )
        }

        if previousPresentationOptions == nil {
            previousPresentationOptions = NSApp.presentationOptions
        }
        if previousWindowLevel == nil {
            previousWindowLevel = window.level
        }
        if previousCollectionBehavior == nil {
            previousCollectionBehavior = window.collectionBehavior
        }

        NSApp.presentationOptions = NSApp.presentationOptions.union([.autoHideMenuBar])
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    func refresh() {
        previewView.refresh()
    }

    func consumeFrame(displayID: CGDirectDisplayID, surface: IOSurface) {
        guard displayID == activeDisplayID else { return }
        previewView.consumeFrame(surface)
    }

    func closeIfDisplayMissing(validDisplayIDs: Set<CGDirectDisplayID>) {
        guard let activeDisplayID else { return }
        guard !validDisplayIDs.contains(activeDisplayID) else { return }
        closePreview()
    }

    func closePreview() {
        guard let window else {
            activeDisplayID = nil
            previewView.displayID = nil
            if let previousPresentationOptions {
                NSApp.presentationOptions = previousPresentationOptions
                self.previousPresentationOptions = nil
            }
            previousWindowLevel = nil
            previousCollectionBehavior = nil
            return
        }

        activeDisplayID = nil
        previewView.displayID = nil
        window.orderOut(nil)

        if let previousWindowLevel {
            window.level = previousWindowLevel
            self.previousWindowLevel = nil
        }
        if let previousCollectionBehavior {
            window.collectionBehavior = previousCollectionBehavior
            self.previousCollectionBehavior = nil
        }
        if let previousPresentationOptions {
            NSApp.presentationOptions = previousPresentationOptions
            self.previousPresentationOptions = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        closePreview()
    }

}

private final class ImmersivePreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class DisplaySurfacePreviewView: NSView {
    var displayID: CGDirectDisplayID? {
        didSet {
            refresh()
        }
    }

    private let surfaceProvider: (CGDirectDisplayID) -> IOSurface?

    private let previewLayer = CALayer()
    private let statusLayer = CATextLayer()

    init(surfaceProvider: @escaping (CGDirectDisplayID) -> IOSurface?) {
        self.surfaceProvider = surfaceProvider
        super.init(frame: .zero)

        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor

        // Fill immersive window by cropping, matching the intended display-like presentation.
        previewLayer.contentsGravity = .resizeAspectFill
        previewLayer.minificationFilter = .trilinear
        previewLayer.magnificationFilter = .linear
        previewLayer.backgroundColor = NSColor.black.cgColor
        previewLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.addSublayer(previewLayer)

        statusLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        statusLayer.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        statusLayer.fontSize = 16
        statusLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
        statusLayer.alignmentMode = .center
        statusLayer.string = "No frame yet"
        layer?.addSublayer(statusLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor {
            statusLayer.contentsScale = scale
            previewLayer.contentsScale = scale
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        statusLayer.frame = CGRect(
            x: 30,
            y: (bounds.height - 24) / 2.0,
            width: max(10, bounds.width - 60),
            height: 24
        )
        CATransaction.commit()
    }

    func refresh() {
        guard let displayID else {
            previewLayer.contents = nil
            statusLayer.isHidden = false
            statusLayer.string = "No display selected"
            return
        }

        if let surface = surfaceProvider(displayID) {
            consumeFrame(surface)
        } else {
            previewLayer.contents = nil
            statusLayer.isHidden = false
            statusLayer.string = "Waiting for frames"
        }
    }

    func consumeFrame(_ surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.contents = surface
        CATransaction.commit()
        statusLayer.isHidden = true
    }
}
