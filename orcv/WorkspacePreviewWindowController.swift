import AppKit
import CoreGraphics
import Foundation
import IOSurface
import QuartzCore

final class WorkspacePreviewWindowController: NSWindowController, NSWindowDelegate {
    private let previewView: DisplaySurfacePreviewView
    private var activeReference: SurfaceReference?
    private var previousPresentationOptions: NSApplication.PresentationOptions?
    private var previousWindowLevel: NSWindow.Level?
    private var previousCollectionBehavior: NSWindow.CollectionBehavior?
    var onDidClosePreview: (() -> Void)?

    init(referenceSurfaceProvider: @escaping (SurfaceReference) -> IOSurface?) {
        previewView = DisplaySurfacePreviewView(referenceSurfaceProvider: referenceSurfaceProvider)

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
        activeReference != nil
    }

    var presentedDisplayID: CGDirectDisplayID? {
        guard let activeReference else { return nil }
        switch activeReference.source {
        case .display(let displayID):
            return displayID
        }
    }

    func presentImmersive(for workspace: Workspace, on targetScreen: NSScreen?) {
        guard let window else { return }

        let reference = SurfaceReference(displayID: workspace.displayID)
        activeReference = reference
        previewView.setReference(reference)
        window.title = workspace.title

        if let targetScreen = targetScreen ?? window.screen ?? NSScreen.screens.first {
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

        // Make immersive preview key so click-away reliably triggers resign and auto-close.
        window.makeKeyAndOrderFront(nil)
        refresh()
    }

    func refresh() {
        previewView.refresh()
    }

    func consumeFrame(displayID: CGDirectDisplayID, surface: IOSurface) {
        guard let activeReference else { return }
        guard case .display(let activeDisplayID) = activeReference.source else { return }
        guard displayID == activeDisplayID else { return }
        previewView.consumeFrame(surface, for: activeReference)
    }

    func closeIfDisplayMissing(validDisplayIDs: Set<CGDirectDisplayID>) {
        guard let activeDisplayID = presentedDisplayID else { return }
        guard !validDisplayIDs.contains(activeDisplayID) else { return }
        closePreview()
    }

    func closePreview() {
        let wasPresenting = activeReference != nil
        let hadSavedWindowState = previousPresentationOptions != nil || previousWindowLevel != nil || previousCollectionBehavior != nil
        guard wasPresenting || hadSavedWindowState else { return }

        guard let window else {
            activeReference = nil
            previewView.setReference(nil)
            if let previousPresentationOptions {
                NSApp.presentationOptions = previousPresentationOptions
                self.previousPresentationOptions = nil
            }
            previousWindowLevel = nil
            previousCollectionBehavior = nil
            if wasPresenting {
                onDidClosePreview?()
            }
            return
        }

        activeReference = nil
        previewView.setReference(nil)
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
        if wasPresenting {
            onDidClosePreview?()
        }
    }

    func windowWillClose(_ notification: Notification) {
        _ = notification
        closePreview()
    }

    func windowDidResignKey(_ notification: Notification) {
        _ = notification
        closePreview()
    }

    func windowDidResignMain(_ notification: Notification) {
        _ = notification
        closePreview()
    }

}

private final class ImmersivePreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class DisplaySurfacePreviewView: NSView {
    private var reference: SurfaceReference?

    private let referenceSurfaceProvider: (SurfaceReference) -> IOSurface?

    private let previewLayer = CALayer()
    private let statusLayer = CATextLayer()

    init(referenceSurfaceProvider: @escaping (SurfaceReference) -> IOSurface?) {
        self.referenceSurfaceProvider = referenceSurfaceProvider
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

    func setReference(_ reference: SurfaceReference?) {
        self.reference = reference
        refresh()
    }

    func refresh() {
        guard let reference else {
            clearPreview(status: "No display selected", reference: nil)
            return
        }

        if let surface = referenceSurfaceProvider(reference) {
            consumeFrame(surface, for: reference)
        } else {
            clearPreview(status: "Waiting for frames", reference: reference)
        }
    }

    func consumeFrame(_ surface: IOSurface, for reference: SurfaceReference) {
        guard self.reference == reference else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.contents = surface
        previewLayer.contentsRect = reference.region.layerContentsRect
        CATransaction.commit()
        statusLayer.isHidden = true
    }

    private func clearPreview(status: String, reference: SurfaceReference?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.contents = nil
        previewLayer.contentsRect = reference?.region.layerContentsRect ?? ReferenceRegion.fullDisplay.layerContentsRect
        CATransaction.commit()
        statusLayer.isHidden = false
        statusLayer.string = status
    }
}
