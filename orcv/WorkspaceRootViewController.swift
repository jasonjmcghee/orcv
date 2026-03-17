import AppKit
import CoreGraphics
import Foundation
import IOSurface
import Metal
import MetalKit

final class WorkspaceRootViewController: NSViewController {
    private struct CanvasCameraState {
        let magnification: CGFloat
        let origin: CGPoint
    }

    private struct CameraHistoryEntry {
        let camera: CanvasCameraState
        let windowFrame: CGRect?
    }

    private struct CanvasSavepoint {
        let camera: CanvasCameraState
        let windowFrame: CGRect?
        let referenceTileID: UUID?
        let cameraOffsetFromTile: CGPoint?
        let seamlessModeEnabled: Bool
    }

    private enum ShiftPanAxisLock {
        case horizontal
        case vertical
    }

    private let displayManager: VirtualDisplayManager
    private let workspaceStore: WorkspaceStore
    private let pointerRouter: PointerRouter
    private let shortcutManager: ShortcutManager
    private let stateStore: WorkspaceStateStore
    private let streamManager = DisplayStreamManager()
    private let hasScreenCaptureAccess: Bool
    private lazy var referenceSurfaceResolver = ReferenceSurfaceResolver(displaySurfaceProvider: { [weak self] displayID in
        self?.streamManager.latestSurface(for: displayID)
    })
    private lazy var previewWindowController = WorkspacePreviewWindowController(referenceSurfaceProvider: { [weak self] reference in
        self?.surface(for: reference)
    })

    private let gridView = OrcvGridView(frame: .zero)
    private let canvasBackdropView = NSVisualEffectView(frame: .zero)
    private let tileStatusOverlay = NSVisualEffectView(frame: .zero)
    private let tileStatusLabel = NSTextField(labelWithString: "")
    private let toastContainer = NSView(frame: .zero)
    private let toastLabel = NSTextField(labelWithString: "")
    private let seamlessFocusBorderView = FocusLockBorderView(frame: .zero)
    private var toastDismissWorkItem: DispatchWorkItem?
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: "")
    private let actionUndoManager = UndoManager()

    private var nextVirtualIndex: Int = 1
    private var localSwipeMonitor: Any?
    private var globalSwipeMonitor: Any?
    private var localCanvasScrollMonitor: Any?
    private var globalCanvasScrollMonitor: Any?
    private var localMagnifyMonitor: Any?
    private var globalMagnifyMonitor: Any?
    private var localMouseMovementMonitor: Any?
    private var globalMouseMovementMonitor: Any?
    private var canvasCameraSaveDebounceWorkItem: DispatchWorkItem?
    private var defaultNotificationObservers: [NSObjectProtocol] = []
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var windowLevelPollingTimer: Timer?
    private var spaceFollowWindowTimer: Timer?
    private var lastSpaceFollowMouseScreenPoint: CGPoint?
    private var isGridWindowFloating = false
    private var lastTeleportTime: TimeInterval = 0
    private var suppressTeleportUntil: TimeInterval = 0
    private var lastImmersiveToggleTime: TimeInterval = 0
    private var immersiveTeleportWorkItem: DispatchWorkItem?
    private var arrangementDebounceWorkItem: DispatchWorkItem?
    private let arrangementDebounceInterval: TimeInterval = 1.0
    private let arrangementApplyQueue = DispatchQueue(label: "today.jason.orcv.arrangement-apply", qos: .utility)
    private var lastAppliedOrigins: [CGDirectDisplayID: CGPoint] = [:]
    private var lastAppliedArrangementSignature: UInt64?
    private var lastQueuedArrangementSignature: UInt64?
    private var arrangementGeneration: UInt64 = 0
    private var pendingArrangementSyncAfterLiveResize = false
    private var lastDisplayModeProbeTime: [CGDirectDisplayID: TimeInterval] = [:]
    private var currentLayoutMode: WorkspaceLayoutMode = .canvas
    private var lastCanvasCamera: CanvasCameraState?
    private var canvasSavepoints: [Int: CanvasSavepoint] = [:]
    private var isRestoringState = false
    private var isMaterializingCanvasOrigins = false
    private var lastObservedWindowFrame: CGRect?
    private var seamlessRestoreWindowFrame: CGRect?
    private var seamlessRestoreCamera: CanvasCameraState?
    private var liveResizeStartCanvasCamera: CanvasCameraState?
    private var isAdjustingCameraForWindowResize = false
    private var suppressProgrammaticWindowResizeCameraAdjustment = false
    private var liveResizeStartWindowFrame: CGRect?
    private var suppressWindowResizeUndoRegistration = false
    private let lifecycleQueue = DispatchQueue(label: "today.jason.orcv.lifecycle", qos: .userInitiated)
    private var didSignalInitialBootstrapComplete = false
    private let minCanvasMagnification: CGFloat = 0.05
    private let maxCanvasMagnification: CGFloat = 8.0
    private let newDisplayPlacementGap: CGFloat = 24.0
    private var alwaysOnTopEnabled = false
    private var showDisplayIDsEnabled = false
    private var centerTileOnJumpEnabled = false
    private var preserveSizeOnSlotJumpEnabled = false
    private var restoreWindowFrameOnSavepointRecallEnabled = true
    private var sharpCornersPreferenceEnabled = false
    private var seamlessModeEnabled = false
    private var seamlessFocusLockEnabled = false
    private var requireHoldingMoveShortcutEnabled = false
    private var swapResizeBehaviorEnabled = false
    private var windowFollowToggleActive = false
    private var moveCursorActive = false
    private var fpsLimitValue: Double = 60.0
    private var unlockFPSIfInteractingEnabled = true
    private var unlockFPSIfLargerThanPercentEnabled = false
    private var unlockFPSLargerThanPercentThreshold: Double = 70.0
    private(set) var arrangePadding: CGFloat = 2.0
    private(set) var autoArrangeMode: ArrangeMode?
    private var pendingScrollZoomDelta: CGFloat = 0.0
    private var shiftPanAxisLock: ShiftPanAxisLock?
    private var streamRefreshWorkItem: DispatchWorkItem?
    private var lastDisplayDescriptorSignature: UInt64?
    private let defaultVisibleDisplayFPS: Double = 60.0
    private let offscreenDisplayFPS: Double = 2.0
    private let backgroundDisplayFPS: Double = 1.0
    private var cameraHistory: [CameraHistoryEntry] = []
    private var cameraHistoryCursor: Int = -1
    private var isNavigatingHistory = false
    private var hasUsedAdjacentJumpSinceBootstrap = false
    private let maxCameraHistoryEntries = 1000

    var onInitialBootstrapComplete: (() -> Void)?
    var onWindowPresentationChange: (() -> Void)?

    init(
        displayManager: VirtualDisplayManager,
        workspaceStore: WorkspaceStore,
        pointerRouter: PointerRouter,
        shortcutManager: ShortcutManager,
        stateStore: WorkspaceStateStore,
        hasScreenCaptureAccess: Bool,
        initialSharpCornersEnabled: Bool = false,
        initialSeamlessModeEnabled: Bool = false
    ) {
        self.displayManager = displayManager
        self.workspaceStore = workspaceStore
        self.pointerRouter = pointerRouter
        self.shortcutManager = shortcutManager
        self.stateStore = stateStore
        self.hasScreenCaptureAccess = hasScreenCaptureAccess
        self.sharpCornersPreferenceEnabled = initialSharpCornersEnabled
        self.seamlessModeEnabled = initialSeamlessModeEnabled
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let localSwipeMonitor {
            NSEvent.removeMonitor(localSwipeMonitor)
        }
        if let globalSwipeMonitor {
            NSEvent.removeMonitor(globalSwipeMonitor)
        }
        if let localCanvasScrollMonitor {
            NSEvent.removeMonitor(localCanvasScrollMonitor)
        }
        if let globalCanvasScrollMonitor {
            NSEvent.removeMonitor(globalCanvasScrollMonitor)
        }
        if let localMagnifyMonitor {
            NSEvent.removeMonitor(localMagnifyMonitor)
        }
        if let globalMagnifyMonitor {
            NSEvent.removeMonitor(globalMagnifyMonitor)
        }
        if let localMouseMovementMonitor {
            NSEvent.removeMonitor(localMouseMovementMonitor)
        }
        if let globalMouseMovementMonitor {
            NSEvent.removeMonitor(globalMouseMovementMonitor)
        }
        canvasCameraSaveDebounceWorkItem?.cancel()
        streamRefreshWorkItem?.cancel()
        immersiveTeleportWorkItem?.cancel()
        windowLevelPollingTimer?.invalidate()
        spaceFollowWindowTimer?.invalidate()
        setMoveCursorActive(false)
        teardownStreamVisibilityObservers()
    }

    override var undoManager: UndoManager? {
        actionUndoManager
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        setupUI()
        wireActions()
        bootstrapDisplays()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        lastObservedWindowFrame = view.window?.frame
        installStreamVisibilityObserversIfNeeded()
        installWindowLevelMonitorIfNeeded()
        installSpaceFollowWindowMonitorIfNeeded()
        installMouseMovementMonitorIfNeeded()
        refreshGridWindowLevelForPointerMapping()
        updateSeamlessMousePassthroughIfNeeded()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        lastObservedWindowFrame = nil
        teardownStreamVisibilityObservers()
        teardownWindowLevelMonitor()
        teardownSpaceFollowWindowMonitor()
        view.window?.ignoresMouseEvents = false
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        adjustCanvasCameraForWindowResizeIfNeeded()
        updateEmptyStateCallout()
        layoutGridDocumentView()
        updateSeamlessMousePassthroughIfNeeded()
        scheduleDisplayStreamRefresh()
        flushPendingArrangementSyncAfterLiveResizeIfNeeded()
    }

    private func setupUI() {
        canvasBackdropView.translatesAutoresizingMaskIntoConstraints = false
        canvasBackdropView.material = .underWindowBackground
        canvasBackdropView.blendingMode = .behindWindow
        canvasBackdropView.state = .active

        gridView.translatesAutoresizingMaskIntoConstraints = false
        gridView.frame = NSRect(x: 0, y: 0, width: 1200, height: 720)

        tileStatusOverlay.translatesAutoresizingMaskIntoConstraints = false
        tileStatusOverlay.material = .underWindowBackground
        tileStatusOverlay.blendingMode = .withinWindow
        tileStatusOverlay.state = .active
        tileStatusOverlay.wantsLayer = true
        tileStatusOverlay.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.72).cgColor
        tileStatusOverlay.isHidden = true

        tileStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        tileStatusLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        tileStatusLabel.textColor = .secondaryLabelColor
        tileStatusLabel.alignment = .center

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.textColor = .labelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.maximumNumberOfLines = 0
        emptyStateLabel.lineBreakMode = .byWordWrapping
        emptyStateLabel.isSelectable = false
        emptyStateLabel.isEditable = false
        emptyStateLabel.isBordered = false
        emptyStateLabel.drawsBackground = false

        tileStatusOverlay.addSubview(tileStatusLabel)

        toastContainer.translatesAutoresizingMaskIntoConstraints = false
        toastContainer.wantsLayer = true
        toastContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.80).cgColor
        toastContainer.layer?.cornerRadius = 8.0
        toastContainer.isHidden = true

        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        toastLabel.textColor = .white
        toastLabel.alignment = .center
        toastLabel.lineBreakMode = .byWordWrapping
        toastLabel.maximumNumberOfLines = 0
        toastContainer.addSubview(toastLabel)

        seamlessFocusBorderView.translatesAutoresizingMaskIntoConstraints = false
        seamlessFocusBorderView.isHidden = true

        view.addSubview(canvasBackdropView)
        view.addSubview(seamlessFocusBorderView)
        view.addSubview(gridView)
        view.addSubview(emptyStateLabel)
        view.addSubview(tileStatusOverlay)
        view.addSubview(toastContainer)

        NSLayoutConstraint.activate([
            canvasBackdropView.topAnchor.constraint(equalTo: view.topAnchor),
            canvasBackdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasBackdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasBackdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            gridView.topAnchor.constraint(equalTo: view.topAnchor),
            gridView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gridView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: gridView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: gridView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: gridView.leadingAnchor, constant: 24),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: gridView.trailingAnchor, constant: -24),
            emptyStateLabel.widthAnchor.constraint(lessThanOrEqualTo: gridView.widthAnchor, multiplier: 0.82),

            tileStatusOverlay.topAnchor.constraint(equalTo: gridView.topAnchor),
            tileStatusOverlay.leadingAnchor.constraint(equalTo: gridView.leadingAnchor),
            tileStatusOverlay.trailingAnchor.constraint(equalTo: gridView.trailingAnchor),
            tileStatusOverlay.bottomAnchor.constraint(equalTo: gridView.bottomAnchor),

            tileStatusLabel.centerXAnchor.constraint(equalTo: tileStatusOverlay.centerXAnchor),
            tileStatusLabel.centerYAnchor.constraint(equalTo: tileStatusOverlay.centerYAnchor),

            toastContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            toastContainer.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),

            toastLabel.topAnchor.constraint(equalTo: toastContainer.topAnchor, constant: 16),
            toastLabel.bottomAnchor.constraint(equalTo: toastContainer.bottomAnchor, constant: -16),
            toastLabel.leadingAnchor.constraint(equalTo: toastContainer.leadingAnchor, constant: 24),
            toastLabel.trailingAnchor.constraint(equalTo: toastContainer.trailingAnchor, constant: -24),

            seamlessFocusBorderView.topAnchor.constraint(equalTo: view.topAnchor),
            seamlessFocusBorderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            seamlessFocusBorderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            seamlessFocusBorderView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        applyInteractionMode()
    }

    private func wireActions() {
        workspaceStore.onDidChange = { [weak self] in
            guard let self else { return }
            self.renderStore()
            self.scheduleStateSave()
        }

        shortcutManager.onDidChange = { [weak self] in
            DispatchQueue.main.async {
                self?.updateEmptyStateCallout()
                self?.renderStore()
            }
        }

        gridView.onFocusRequest = { [weak self] workspaceID, pointInTile, frameInGrid, modifiers in
            guard let self else { return }
            _ = pointInTile
            _ = frameInGrid
            if self.consumeSeamlessFocusLockClick() {
                return
            }
            if modifiers.contains(.command) || modifiers.contains(.shift) {
                self.workspaceStore.toggleSelection(workspaceID: workspaceID)
            } else {
                self.workspaceStore.selectOnly(workspaceID: workspaceID)
            }
        }

        gridView.onBackgroundClick = { [weak self] in
            if self?.consumeSeamlessFocusLockClick() == true {
                return
            }
            self?.workspaceStore.clearSelection()
        }
        gridView.onBackgroundWindowDragRequest = { [weak self] event in
            guard let self, let window = self.view.window else { return }
            if self.consumeSeamlessFocusLockClick() {
                return
            }
            if !self.isOrcvWindowFocused() {
                NSApp.activate(ignoringOtherApps: true)
            }
            window.performDrag(with: event)
        }

        gridView.onReorderCommit = { [weak self] orderedIDs in
            guard let self else { return }
            let previousOrder = self.workspaceStore.workspaces.map(\.id)
            self.workspaceStore.reorderWorkspaces(orderedIDs)
            let appliedOrder = self.workspaceStore.workspaces.map(\.id)
            self.scheduleArrangementSync()
            self.registerOrderUndo(from: previousOrder, to: appliedOrder, actionName: "Reorder Displays")
        }

        gridView.onCanvasMoveCommit = { [weak self] workspaceID, newOrigin, oldOrigin in
            guard let self else { return }
            self.workspaceStore.updateCanvasOrigin(workspaceID: workspaceID, origin: newOrigin)
            self.scheduleArrangementSync()
            if let oldOrigin {
                self.registerUndoForMove(workspaceID: workspaceID, from: oldOrigin, to: newOrigin)
            }
            self.autoArrangeIfNeeded()
        }

        gridView.layoutMode = .canvas
        gridView.showsDisplayIDs = showDisplayIDsEnabled

        gridView.referenceProvider = { [weak self] workspace in
            self?.reference(for: workspace) ?? SurfaceReference(displayID: workspace.displayID)
        }
        gridView.referenceSurfaceProvider = { [weak self] reference in
            self?.surface(for: reference)
        }

        streamManager.onFrame = nil

        streamManager.onDisplayFrame = { [weak self] displayID, surface in
            self?.gridView.refreshPreviews(for: displayID)
            self?.previewWindowController.consumeFrame(displayID: displayID, surface: surface)
            self?.maybeRefreshDisplayPixelSizeFromSystem(displayID: displayID, surface: surface)
        }

        streamManager.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.setTileStatus(message)
            }
        }

        previewWindowController.onDidClosePreview = { [weak self] in
            self?.refreshGridWindowLevelForPointerMapping()
        }

        installSwipeMonitorsIfNeeded()
        installMagnificationMonitorIfNeeded()
        installCanvasScrollMonitorsIfNeeded()
        updateEmptyStateCallout()
    }

    private func bootstrapDisplays() {
        setTileStatus("Loading displays...")
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            let bootstrap = self.buildBootstrapState()
            DispatchQueue.main.async {
                self.applyBootstrapState(bootstrap)
            }
        }
    }

    private func renderStore() {
        updateEmptyStateCallout()
        gridView.displayIndexByDisplayID = displayManager.systemDisplayIndexByID()
        gridView.workspaces = workspaceStore.workspaces
        gridView.focusedWorkspaceID = workspaceStore.focusedWorkspaceID
        gridView.selectedWorkspaceIDs = workspaceStore.selectedWorkspaceIDs
        layoutGridDocumentView()
        materializeUnpositionedCanvasOriginsIfNeeded()
        updateSeamlessMousePassthroughIfNeeded()

        let validDisplayIDs = Set(workspaceStore.workspaces.map(\.displayID))
        previewWindowController.closeIfDisplayMissing(validDisplayIDs: validDisplayIDs)
        refreshGridWindowLevelForPointerMapping()
        scheduleDisplayStreamRefresh()
    }

    private func installStreamVisibilityObserversIfNeeded() {
        guard defaultNotificationObservers.isEmpty, workspaceNotificationObservers.isEmpty else { return }
        guard let window = view.window else { return }

        let center = NotificationCenter.default
        let refresh: (Notification) -> Void = { [weak self] _ in
            self?.scheduleDisplayStreamRefresh(immediate: true)
        }

        defaultNotificationObservers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main,
            using: refresh
        ))
        defaultNotificationObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main,
            using: refresh
        ))
        defaultNotificationObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main,
            using: refresh
        ))
        defaultNotificationObservers.append(center.addObserver(
            forName: NSApplication.didHideNotification,
            object: nil,
            queue: .main,
            using: refresh
        ))
        defaultNotificationObservers.append(center.addObserver(
            forName: NSApplication.didUnhideNotification,
            object: nil,
            queue: .main,
            using: refresh
        ))

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceNotificationObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main,
            using: refresh
        ))
    }

    private func teardownStreamVisibilityObservers() {
        let center = NotificationCenter.default
        for observer in defaultNotificationObservers {
            center.removeObserver(observer)
        }
        defaultNotificationObservers.removeAll(keepingCapacity: true)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceNotificationObservers {
            workspaceCenter.removeObserver(observer)
        }
        workspaceNotificationObservers.removeAll(keepingCapacity: true)
    }

    private func materializeUnpositionedCanvasOriginsIfNeeded() {
        guard currentLayoutMode == .canvas else { return }
        guard !isMaterializingCanvasOrigins else { return }

        let unpositioned = workspaceStore.workspaces.filter { $0.canvasOrigin == nil }
        guard !unpositioned.isEmpty else { return }

        var origins: [UUID: CGPoint] = [:]
        for workspace in unpositioned {
            guard let frame = gridView.frameForWorkspaceInWorld(workspace.id) else { continue }
            origins[workspace.id] = frame.origin
        }
        guard !origins.isEmpty else { return }

        isMaterializingCanvasOrigins = true
        workspaceStore.setCanvasOrigins(origins)
        isMaterializingCanvasOrigins = false
    }

    private func updateEmptyStateCallout() {
        let shortcut = shortcutManager.displayLabel(for: .newDisplay)
        gridView.emptyStateCreateShortcutLabel = shortcut

        let width = max(1.0, gridView.bounds.width)
        let titleSize = max(28.0, min(92.0, width * 0.085))
        let subtitleSize = max(16.0, min(42.0, width * 0.036))

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = max(6.0, width * 0.005)

        let title = NSAttributedString(
            string: "No Displays Open",
            attributes: [
                .font: NSFont.systemFont(ofSize: titleSize, weight: .bold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        let subtitle = NSAttributedString(
            string: "Press \(shortcut) to create your first display",
            attributes: [
                .font: NSFont.systemFont(ofSize: subtitleSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
        let message = NSMutableAttributedString(attributedString: title)
        message.append(NSAttributedString(string: "\n"))
        message.append(subtitle)
        emptyStateLabel.attributedStringValue = message
        emptyStateLabel.isHidden = !workspaceStore.workspaces.isEmpty
    }

    private func adjustCanvasCameraForWindowResizeIfNeeded() {
        if suppressProgrammaticWindowResizeCameraAdjustment {
            lastObservedWindowFrame = view.window?.frame
            return
        }
        guard currentLayoutMode == .canvas else {
            lastObservedWindowFrame = view.window?.frame
            return
        }
        guard !workspaceStore.workspaces.isEmpty else {
            lastObservedWindowFrame = view.window?.frame
            return
        }
        guard let window = view.window else { return }

        let newFrame = window.frame
        defer { lastObservedWindowFrame = newFrame }
        guard let oldFrame = lastObservedWindowFrame else { return }

        let oldSize = oldFrame.size
        let newSize = newFrame.size
        guard abs(newSize.width - oldSize.width) > 0.01 || abs(newSize.height - oldSize.height) > 0.01 else {
            return
        }
        guard !isAdjustingCameraForWindowResize else { return }

        let modifierActive = shortcutManager.isScalingResizeModifierActive()
        let shouldStretchWithResize = swapResizeBehaviorEnabled ? modifierActive : !modifierActive
        guard let adjustedCamera = adjustedCanvasCamera(
            from: oldFrame,
            to: newFrame,
            stretchWithResize: shouldStretchWithResize
        ) else { return }
        let oldMagnification = max(0.01, gridView.cameraMagnification)
        let oldOrigin = gridView.cameraOrigin
        let newMagnification = adjustedCamera.magnification
        let newOrigin = adjustedCamera.origin

        guard abs(newOrigin.x - oldOrigin.x) > 0.0001
            || abs(newOrigin.y - oldOrigin.y) > 0.0001
            || abs(newMagnification - oldMagnification) > 0.0001 else {
            return
        }

        isAdjustingCameraForWindowResize = true
        if abs(newMagnification - oldMagnification) > 0.0001 {
            gridView.cameraMagnification = newMagnification
        }
        gridView.cameraOrigin = newOrigin
        lastCanvasCamera = currentCanvasCameraState() ?? lastCanvasCamera
        scheduleCanvasCameraSaveDebounced()
        isAdjustingCameraForWindowResize = false
    }

    func applyWindowFramePreservingCanvas(_ targetFrame: CGRect, stretchWithResize: Bool = true) {
        guard let window = view.window else { return }
        let oldFrame = window.frame
        let targetCamera = adjustedCanvasCamera(
            from: oldFrame,
            to: targetFrame,
            stretchWithResize: stretchWithResize
        )

        suppressWindowResizeUndoRegistration = true
        suppressProgrammaticWindowResizeCameraAdjustment = true
        window.setFrame(targetFrame, display: true, animate: false)
        lastObservedWindowFrame = targetFrame
        if let targetCamera {
            applyCanvasCamera(targetCamera)
            scheduleCanvasCameraSaveDebounced()
        }
        suppressProgrammaticWindowResizeCameraAdjustment = false
        suppressWindowResizeUndoRegistration = false
    }

    func applyWindowFramePreservingScreenProjection(_ targetFrame: CGRect) {
        guard let window = view.window else { return }
        let oldFrame = window.frame
        let targetCamera = adjustedCanvasCameraPreservingScreenProjection(
            from: oldFrame,
            to: targetFrame
        )

        suppressWindowResizeUndoRegistration = true
        suppressProgrammaticWindowResizeCameraAdjustment = true
        window.setFrame(targetFrame, display: true, animate: false)
        lastObservedWindowFrame = targetFrame
        if let targetCamera {
            applyCanvasCamera(targetCamera)
            scheduleCanvasCameraSaveDebounced()
        }
        suppressProgrammaticWindowResizeCameraAdjustment = false
        suppressWindowResizeUndoRegistration = false
    }

    func applyWindowFrameWithoutAdjustingCanvas(_ targetFrame: CGRect) {
        guard let window = view.window else { return }
        suppressWindowResizeUndoRegistration = true
        suppressProgrammaticWindowResizeCameraAdjustment = true
        window.setFrame(targetFrame, display: true, animate: false)
        lastObservedWindowFrame = targetFrame
        suppressProgrammaticWindowResizeCameraAdjustment = false
        suppressWindowResizeUndoRegistration = false
    }

    private func adjustedCanvasCamera(
        from oldFrame: CGRect,
        to newFrame: CGRect,
        stretchWithResize: Bool
    ) -> CanvasCameraState? {
        guard currentLayoutMode == .canvas else { return nil }
        guard !workspaceStore.workspaces.isEmpty else { return nil }

        let oldSize = oldFrame.size
        let newSize = newFrame.size
        guard abs(newSize.width - oldSize.width) > 0.01 || abs(newSize.height - oldSize.height) > 0.01 else {
            return currentCanvasCameraState() ?? lastCanvasCamera
        }

        let oldMagnification = max(0.01, gridView.cameraMagnification)
        var newMagnification = oldMagnification
        if stretchWithResize, oldSize.width > 1.0, newSize.width > 1.0 {
            newMagnification = oldMagnification * (newSize.width / oldSize.width)
            newMagnification = max(minCanvasMagnification, min(maxCanvasMagnification, newMagnification))
        }

        let edgeEpsilon: CGFloat = 0.5
        let leftMoved = abs(newFrame.minX - oldFrame.minX) > edgeEpsilon
        let rightMoved = abs(newFrame.maxX - oldFrame.maxX) > edgeEpsilon
        let bottomMoved = abs(newFrame.minY - oldFrame.minY) > edgeEpsilon
        let topMoved = abs(newFrame.maxY - oldFrame.maxY) > edgeEpsilon

        let oldAnchorX: CGFloat
        let newAnchorX: CGFloat
        if leftMoved && !rightMoved {
            oldAnchorX = oldSize.width
            newAnchorX = newSize.width
        } else if rightMoved && !leftMoved {
            oldAnchorX = 0.0
            newAnchorX = 0.0
        } else {
            oldAnchorX = oldSize.width / 2.0
            newAnchorX = newSize.width / 2.0
        }

        let oldAnchorY: CGFloat
        let newAnchorY: CGFloat
        if bottomMoved && !topMoved {
            oldAnchorY = oldSize.height
            newAnchorY = newSize.height
        } else if topMoved && !bottomMoved {
            oldAnchorY = 0.0
            newAnchorY = 0.0
        } else {
            oldAnchorY = oldSize.height / 2.0
            newAnchorY = newSize.height / 2.0
        }

        let oldOrigin = gridView.cameraOrigin
        let anchoredWorldPoint = CGPoint(
            x: oldOrigin.x + oldAnchorX / oldMagnification,
            y: oldOrigin.y + oldAnchorY / oldMagnification
        )
        let newOrigin = CGPoint(
            x: anchoredWorldPoint.x - newAnchorX / newMagnification,
            y: anchoredWorldPoint.y - newAnchorY / newMagnification
        )

        return CanvasCameraState(magnification: newMagnification, origin: newOrigin)
    }

    private func adjustedCanvasCameraPreservingScreenProjection(
        from oldFrame: CGRect,
        to newFrame: CGRect
    ) -> CanvasCameraState? {
        guard currentLayoutMode == .canvas else { return nil }
        guard !workspaceStore.workspaces.isEmpty else { return nil }

        let magnification = max(0.01, gridView.cameraMagnification)
        let oldOrigin = gridView.cameraOrigin
        let deltaX = newFrame.minX - oldFrame.minX
        let deltaY = newFrame.minY - oldFrame.minY
        let newOrigin = CGPoint(
            x: oldOrigin.x + deltaX / magnification,
            y: oldOrigin.y + deltaY / magnification
        )
        return CanvasCameraState(magnification: magnification, origin: newOrigin)
    }

    @objc
    private func handleNewDisplay() {
        let templateTileSize = workspaceStore.focusedWorkspace?.tileSize ?? workspaceStore.workspaces.first?.tileSize
        guard let created = createVirtualWorkspace(
            name: "\(nextVirtualIndex)",
            tileSize: templateTileSize,
            at: nil
        ) else {
            NSSound.beep()
            return
        }

        if let targetOrigin = preferredCanvasOriginForNewWorkspace(workspaceID: created.id) {
            workspaceStore.updateCanvasOrigin(workspaceID: created.id, origin: targetOrigin)
            scheduleArrangementSync()
        }

        nextVirtualIndex += 1
        registerUndoForCreate(workspaceID: created.id, actionName: "New Display")
        autoArrangeIfNeeded()
    }

    @objc
    private func handleRemoveHovered() {
        guard let window = view.window else { return }
        let mouseInScreen = NSEvent.mouseLocation
        guard isPointerDirectlyOverWindow(window: window, screenPoint: mouseInScreen) else { return }
        let pointInWindow = window.convertPoint(fromScreen: mouseInScreen)
        let pointInGrid = gridView.convert(pointInWindow, from: nil)

        guard let hit = gridView.hitTestWorkspace(at: pointInGrid),
              let workspace = workspaceStore.workspace(with: hit.workspaceID),
              workspace.kind == .virtual else {
            let shortcutLabel = shortcutManager.displayString(for: .removeDisplay)
            showToast("Hover over the desired desktop and then press \(shortcutLabel) to close")
            return
        }
        guard let removed = removeVirtualWorkspace(workspaceID: workspace.id) else {
            NSSound.beep()
            return
        }
        registerUndoForDelete(removed: removed.workspace, index: removed.index, actionName: "Remove Display")
        autoArrangeIfNeeded()
    }

    private func currentDisplayDescriptors() -> [DisplayDescriptor] {
        let workspaces = workspaceStore.workspaces
        guard !workspaces.isEmpty else { return [] }
        let interactionUnlockDisplayID = interactingDisplayIDFromMouse()
        let viewport = gridView.bounds
        let viewportArea = max(1.0, viewport.width * viewport.height)

        if let immersiveDisplayID = previewWindowController.presentedDisplayID {
            let immersiveFPS = effectiveVisibleDisplayFPS(
                visibleRect: nil,
                viewportArea: viewportArea,
                interactionUnlockForDisplay: interactionUnlockDisplayID == immersiveDisplayID
            )
            return workspaces.map { workspace in
                DisplayDescriptor(
                    displayID: workspace.displayID,
                    title: workspace.title,
                    pixelSize: workspace.displayPixelSize,
                    kind: workspace.kind,
                    maxFPS: workspace.displayID == immersiveDisplayID ? immersiveFPS : backgroundDisplayFPS
                )
            }
        }

        let windowVisible = isOrcvWindowVisibleForCapture()
        let window = view.window

        return workspaces.map { workspace in
            let targetFPS: Double
            if unlockFPSIfInteractingEnabled, interactionUnlockDisplayID == workspace.displayID {
                targetFPS = max(clampedFPSLimit(fpsLimitValue), defaultVisibleDisplayFPS)
            } else if !windowVisible {
                targetFPS = backgroundDisplayFPS
            } else if let frameInGrid = gridView.frameForWorkspaceInGrid(workspace.id) {
                let visibleRect = frameInGrid.intersection(viewport)
                let isVisibleInViewport = !visibleRect.isNull && visibleRect.width > 1.0 && visibleRect.height > 1.0
                if !isVisibleInViewport {
                    targetFPS = offscreenDisplayFPS
                } else if let window, isWorkspaceLikelyOccludedByOtherWindow(frameInGrid: frameInGrid, window: window) {
                    targetFPS = offscreenDisplayFPS
                } else {
                    targetFPS = effectiveVisibleDisplayFPS(
                        visibleRect: visibleRect,
                        viewportArea: viewportArea,
                        interactionUnlockForDisplay: interactionUnlockDisplayID == workspace.displayID
                    )
                }
            } else {
                targetFPS = offscreenDisplayFPS
            }

            return DisplayDescriptor(
                displayID: workspace.displayID,
                title: workspace.title,
                pixelSize: workspace.displayPixelSize,
                kind: workspace.kind,
                maxFPS: targetFPS
            )
        }
    }

    private func effectiveVisibleDisplayFPS(
        visibleRect: CGRect?,
        viewportArea: CGFloat,
        interactionUnlockForDisplay: Bool
    ) -> Double {
        var fps = clampedFPSLimit(fpsLimitValue)
        if unlockFPSIfInteractingEnabled, interactionUnlockForDisplay {
            fps = max(fps, defaultVisibleDisplayFPS)
        }
        if shouldUnlockFPSForVisibleCoverage(visibleRect: visibleRect, viewportArea: viewportArea) {
            fps = max(fps, defaultVisibleDisplayFPS)
        }
        return fps
    }

    private func interactingDisplayIDFromMouse() -> CGDirectDisplayID? {
        guard unlockFPSIfInteractingEnabled else { return nil }
        return workspaceUnderCurrentMouseDisplay()?.displayID
    }

    private func shouldUnlockFPSForVisibleCoverage(visibleRect: CGRect?, viewportArea: CGFloat) -> Bool {
        guard unlockFPSIfLargerThanPercentEnabled else { return false }
        guard let visibleRect, !visibleRect.isNull else { return false }
        guard viewportArea > 1.0 else { return false }
        let coverage = max(0.0, min(100.0, (visibleRect.width * visibleRect.height) / viewportArea * 100.0))
        return coverage >= unlockFPSLargerThanPercentThreshold
    }

    private func clampedFPSLimit(_ value: Double) -> Double {
        guard value.isFinite else { return defaultVisibleDisplayFPS }
        return min(120.0, max(1.0, value))
    }

    private func clampedFPSUnlockCoverageThreshold(_ value: Double) -> Double {
        guard value.isFinite else { return 70.0 }
        return min(100.0, max(1.0, value))
    }

    private func isOrcvWindowVisibleForCapture() -> Bool {
        guard let window = view.window else { return true }
        guard window.isVisible else { return false }
        return window.occlusionState.contains(.visible)
    }

    private func isWorkspaceLikelyOccludedByOtherWindow(frameInGrid: CGRect, window: NSWindow) -> Bool {
        guard frameInGrid.width > 1.0, frameInGrid.height > 1.0 else { return false }
        let sampleInGrid = CGPoint(x: frameInGrid.midX, y: frameInGrid.midY)
        let sampleInWindow = gridView.convert(sampleInGrid, to: nil)
        let sampleInScreen = window.convertPoint(toScreen: sampleInWindow)
        let topWindowNumber = NSWindow.windowNumber(at: sampleInScreen, belowWindowWithWindowNumber: 0)
        guard topWindowNumber > 0 else { return false }
        return topWindowNumber != window.windowNumber
    }

    private func displayDescriptorSignature(_ descriptors: [DisplayDescriptor]) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(descriptors.count)
        for descriptor in descriptors {
            hasher.combine(Int(descriptor.displayID))
            hasher.combine(Int(descriptor.pixelSize.width.rounded()))
            hasher.combine(Int(descriptor.pixelSize.height.rounded()))
            hasher.combine(Int((descriptor.maxFPS * 100.0).rounded()))
        }
        let signed = Int64(hasher.finalize())
        return UInt64(bitPattern: signed)
    }

    private func refreshDisplayStreams(force: Bool = false) {
        guard hasScreenCaptureAccess else { return }
        let descriptors = currentDisplayDescriptors()
        let signature = displayDescriptorSignature(descriptors)
        if !force, signature == lastDisplayDescriptorSignature {
            return
        }
        lastDisplayDescriptorSignature = signature
        streamManager.configureStreams(for: descriptors)
    }

    private func scheduleDisplayStreamRefresh(immediate: Bool = false, force: Bool = false) {
        guard hasScreenCaptureAccess else { return }
        streamRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshDisplayStreams(force: force)
        }
        streamRefreshWorkItem = workItem
        if immediate {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
        }
    }

    private func reference(for workspace: Workspace) -> SurfaceReference {
        SurfaceReference(displayID: workspace.displayID)
    }

    private func surface(for reference: SurfaceReference) -> IOSurface? {
        referenceSurfaceResolver.surface(for: reference)
    }

    func flushStateNow() {
        stateStore.flushNow(makeSnapshot())
    }

    func menuNewDisplay() {
        handleNewDisplay()
    }

    func menuRemoveFocusedDisplay() {
        handleRemoveHovered()
    }

    func menuToggleTeleport() {
        toggleTeleport()
    }

    func menuJumpNextDisplay() {
        _ = jumpToAdjacentDisplay(step: 1)
    }

    func menuJumpPreviousDisplay() {
        _ = jumpToAdjacentDisplay(step: -1)
    }

    func menuNavigateBack() {
        _ = navigateCameraBack()
    }

    func menuNavigateForward() {
        _ = navigateCameraForward()
    }

    func menuDeselectTile() {
        workspaceStore.clearSelection()
    }

    func menuToggleAlwaysOnTop() {
        alwaysOnTopEnabled.toggle()
        refreshGridWindowLevelForPointerMapping()
    }

    func menuAlwaysOnTopEnabled() -> Bool {
        alwaysOnTopEnabled
    }

    func menuToggleShowDisplayIDs() {
        showDisplayIDsEnabled.toggle()
        gridView.showsDisplayIDs = showDisplayIDsEnabled
    }

    func menuShowDisplayIDsEnabled() -> Bool {
        showDisplayIDsEnabled
    }

    func menuToggleCenterTileOnJump() {
        centerTileOnJumpEnabled.toggle()
    }

    func menuCenterTileOnJumpEnabled() -> Bool {
        centerTileOnJumpEnabled
    }

    func menuTogglePreserveSizeOnSlotJump() {
        preserveSizeOnSlotJumpEnabled.toggle()
    }

    func menuPreserveSizeOnSlotJumpEnabled() -> Bool {
        preserveSizeOnSlotJumpEnabled
    }

    func menuToggleRestoreWindowFrameOnSavepointRecall() {
        restoreWindowFrameOnSavepointRecallEnabled.toggle()
    }

    func menuRestoreWindowFrameOnSavepointRecallEnabled() -> Bool {
        restoreWindowFrameOnSavepointRecallEnabled
    }

    func menuToggleRequireHoldingMoveShortcut() {
        requireHoldingMoveShortcutEnabled.toggle()
        if requireHoldingMoveShortcutEnabled {
            setWindowFollowToggleActive(false)
        } else {
            updateSpaceFollowWindowIfNeeded()
        }
        scheduleStateSave()
    }

    func menuRequireHoldingMoveShortcutEnabled() -> Bool {
        requireHoldingMoveShortcutEnabled
    }

    func menuToggleSwapResizeBehavior() {
        swapResizeBehaviorEnabled.toggle()
    }

    func menuSwapResizeBehaviorEnabled() -> Bool {
        swapResizeBehaviorEnabled
    }

    func menuToggleSharpCorners() {
        sharpCornersPreferenceEnabled.toggle()
        applyWindowPresentationPreferences()
        scheduleStateSave()
    }

    func menuSharpCornersEnabled() -> Bool {
        sharpCornersPreferenceEnabled
    }

    func menuToggleSeamlessMode() {
        setSeamlessModeEnabled(!seamlessModeEnabled)
    }

    func menuSeamlessModeEnabled() -> Bool {
        seamlessModeEnabled
    }

    func setSeamlessRestoreWindowFrame(_ frame: CGRect?, scheduleSave: Bool = true) {
        seamlessRestoreWindowFrame = frame
        if scheduleSave {
            scheduleStateSave()
        }
    }

    func captureSeamlessRestoreSnapshot(scheduleSave: Bool = true) {
        seamlessRestoreWindowFrame = view.window?.frame ?? lastObservedWindowFrame
        seamlessRestoreCamera = currentCanvasCameraState() ?? lastCanvasCamera
        if scheduleSave {
            scheduleStateSave()
        }
    }

    func applySeamlessRestoreSnapshot() {
        if let frame = seamlessRestoreWindowFrame {
            applyWindowFrameWithoutAdjustingCanvas(frame)
        }
        if let camera = seamlessRestoreCamera {
            applyCanvasCamera(camera)
            scheduleCanvasCameraSaveDebounced()
        }
    }

    func seamlessFocusLockIsEnabled() -> Bool {
        seamlessFocusLockEnabled
    }

    func setSeamlessFocusLockEnabled(_ enabled: Bool) {
        let resolved = enabled && seamlessModeEnabled
        guard seamlessFocusLockEnabled != resolved else { return }
        seamlessFocusLockEnabled = resolved
        applyWindowPresentationPreferences()
    }

    func menuArrange(_ mode: ArrangeMode) {
        performArrange(mode)
    }

    func menuSetAutoArrangeMode(_ mode: ArrangeMode?) {
        autoArrangeMode = mode
        if let mode {
            performArrange(mode)
        }
        scheduleStateSave()
    }

    func menuAutoArrangeMode() -> ArrangeMode? {
        autoArrangeMode
    }

    func menuArrangePadding() -> CGFloat {
        arrangePadding
    }

    func menuSetArrangePadding(_ padding: CGFloat) {
        arrangePadding = max(0, padding)
        if let mode = autoArrangeMode {
            performArrange(mode)
        }
        scheduleStateSave()
    }

    func menuLimitFPSValue() -> Double {
        fpsLimitValue
    }

    func menuUnlockFPSIfInteractingEnabled() -> Bool {
        unlockFPSIfInteractingEnabled
    }

    func menuUnlockFPSIfLargerThanPercentEnabled() -> Bool {
        unlockFPSIfLargerThanPercentEnabled
    }

    func menuUnlockFPSLargerThanPercentThreshold() -> Double {
        unlockFPSLargerThanPercentThreshold
    }

    func menuSetLimitFPSSettings(
        limitFPS: Double,
        unlockIfInteracting: Bool,
        unlockIfLargerThanPercent: Bool,
        unlockIfLargerThresholdPercent: Double
    ) {
        fpsLimitValue = clampedFPSLimit(limitFPS)
        unlockFPSIfInteractingEnabled = unlockIfInteracting
        unlockFPSIfLargerThanPercentEnabled = unlockIfLargerThanPercent
        unlockFPSLargerThanPercentThreshold = clampedFPSUnlockCoverageThreshold(unlockIfLargerThresholdPercent)
        scheduleDisplayStreamRefresh(immediate: true, force: true)
        scheduleStateSave()
    }

    private func performArrange(_ mode: ArrangeMode, pushHistory: Bool = true) {
        let workspaces = workspaceStore.workspaces
        guard !workspaces.isEmpty else { return }

        // Capture old origins for undo.
        let oldOrigins = Dictionary(uniqueKeysWithValues: workspaces.compactMap { ws -> (UUID, CGPoint)? in
            guard let origin = ws.canvasOrigin else { return nil }
            return (ws.id, origin)
        })

        let tiles = workspaces.map { workspace in
            ArrangeLayout.Tile(
                id: workspace.id,
                size: workspace.tileSize,
                currentOrigin: workspace.canvasOrigin ?? .zero
            )
        }

        let newOrigins = ArrangeLayout.arrange(mode: mode, tiles: tiles, padding: arrangePadding)
        workspaceStore.setCanvasOrigins(newOrigins)
        scheduleArrangementSync()
        scheduleStateSave()

        if pushHistory {
            registerUndoForArrange(from: oldOrigins, to: newOrigins)
        }
    }

    private func autoArrangeIfNeeded() {
        guard let mode = autoArrangeMode else { return }
        performArrange(mode, pushHistory: false)
    }

    func windowWillStartLiveResize(_ window: NSWindow) {
        guard window == view.window else { return }
        liveResizeStartWindowFrame = window.frame
        liveResizeStartCanvasCamera = currentCanvasCameraState() ?? lastCanvasCamera
    }

    private var moveStartWindowFrame: CGRect?
    private var moveUndoWorkItem: DispatchWorkItem?

    func windowWillMove(_ window: NSWindow) {
        guard window == view.window else { return }
        if moveStartWindowFrame == nil {
            moveStartWindowFrame = window.frame
        }
    }

    func windowDidMove(_ window: NSWindow) {
        guard window == view.window else { return }
        guard !suppressWindowResizeUndoRegistration else { return }
        moveUndoWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let before = self.moveStartWindowFrame else { return }
            self.moveStartWindowFrame = nil
            let after = window.frame
            self.lastObservedWindowFrame = after
            if !self.seamlessModeEnabled {
                self.seamlessRestoreWindowFrame = after
                self.seamlessRestoreCamera = self.currentCanvasCameraState() ?? self.lastCanvasCamera
            }
            guard self.windowFramesDiffer(before, after) else { return }
            let camera = self.currentCanvasCameraState() ?? self.lastCanvasCamera
            self.registerWindowResizeUndo(
                from: before,
                to: after,
                beforeCamera: camera,
                afterCamera: camera,
                actionName: "Move Window"
            )
            self.scheduleStateSave()
        }
        moveUndoWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func windowDidEndLiveResize(_ window: NSWindow) {
        guard window == view.window else { return }
        defer {
            liveResizeStartWindowFrame = nil
            liveResizeStartCanvasCamera = nil
        }
        guard !suppressWindowResizeUndoRegistration else { return }
        guard let before = liveResizeStartWindowFrame else { return }
        let after = window.frame
        let beforeCamera = liveResizeStartCanvasCamera
        let afterCamera = currentCanvasCameraState() ?? lastCanvasCamera
        registerWindowResizeUndo(
            from: before,
            to: after,
            beforeCamera: beforeCamera,
            afterCamera: afterCamera,
            actionName: "Resize Window"
        )
        lastObservedWindowFrame = after
        if !seamlessModeEnabled {
            seamlessRestoreWindowFrame = after
            seamlessRestoreCamera = currentCanvasCameraState() ?? lastCanvasCamera
        }
        scheduleStateSave()
    }

    private struct DeletedWorkspaceSnapshot {
        let title: String
        let tileSize: CGSize
        let index: Int
    }

    @discardableResult
    private func createVirtualWorkspace(name: String, tileSize: CGSize?, at index: Int?) -> Workspace? {
        let profile = displayManager.mainDisplayProfile()
        guard let descriptor = displayManager.createVirtualDisplay(
            name: name,
            width: profile.width,
            height: profile.height,
            hidpi: profile.hiDPI,
            physicalSizeMM: profile.physicalSizeMM
        ) else {
            return nil
        }

        let created = workspaceStore.addWorkspace(from: descriptor, tileSize: tileSize, at: index)
        scheduleDisplayStreamRefresh(immediate: true, force: true)
        scheduleArrangementSync()
        return created
    }

    @discardableResult
    private func removeVirtualWorkspace(workspaceID: UUID) -> (workspace: Workspace, index: Int)? {
        guard let workspace = workspaceStore.workspace(with: workspaceID),
              workspace.kind == .virtual else {
            return nil
        }
        guard displayManager.removeVirtualDisplay(displayID: workspace.displayID) else {
            return nil
        }
        guard let removed = workspaceStore.removeWorkspace(id: workspaceID) else {
            return nil
        }
        scheduleDisplayStreamRefresh(immediate: true, force: true)
        scheduleArrangementSync()
        return removed
    }

    private func registerUndoForCreate(workspaceID: UUID, actionName: String) {
        actionUndoManager.registerUndo(withTarget: self) { target in
            guard let removed = target.removeVirtualWorkspace(workspaceID: workspaceID) else { return }
            target.registerUndoForDelete(removed: removed.workspace, index: removed.index, actionName: actionName)
            target.autoArrangeIfNeeded()
        }
        actionUndoManager.setActionName(actionName)
    }

    private func registerUndoForDelete(removed: Workspace, index: Int, actionName: String) {
        let snapshot = DeletedWorkspaceSnapshot(
            title: removed.title,
            tileSize: removed.tileSize,
            index: index
        )
        actionUndoManager.registerUndo(withTarget: self) { target in
            guard let recreated = target.createVirtualWorkspace(
                name: snapshot.title,
                tileSize: snapshot.tileSize,
                at: snapshot.index
            ) else { return }
            target.registerUndoForCreate(workspaceID: recreated.id, actionName: actionName)
            target.autoArrangeIfNeeded()
        }
        actionUndoManager.setActionName(actionName)
    }

    private func registerUndoForMove(workspaceID: UUID, from oldOrigin: CGPoint, to newOrigin: CGPoint) {
        actionUndoManager.registerUndo(withTarget: self) { target in
            target.workspaceStore.updateCanvasOrigin(workspaceID: workspaceID, origin: oldOrigin)
            target.scheduleArrangementSync()
            target.scheduleStateSave()
            target.registerUndoForMove(workspaceID: workspaceID, from: newOrigin, to: oldOrigin)
            target.autoArrangeIfNeeded()
        }
        actionUndoManager.setActionName("Move Tile")
    }

    private func registerUndoForArrange(from oldOrigins: [UUID: CGPoint], to newOrigins: [UUID: CGPoint]) {
        actionUndoManager.registerUndo(withTarget: self) { target in
            target.workspaceStore.setCanvasOrigins(oldOrigins)
            target.scheduleArrangementSync()
            target.scheduleStateSave()
            target.registerUndoForArrange(from: newOrigins, to: oldOrigins)
        }
        actionUndoManager.setActionName("Arrange")
    }

    private func preferredCanvasOriginForNewWorkspace(workspaceID: UUID) -> CGPoint? {
        guard currentLayoutMode == .canvas else { return nil }
        guard let workspace = workspaceStore.workspace(with: workspaceID) else { return nil }
        let tileSize = workspace.tileSize
        guard tileSize.width > 1, tileSize.height > 1 else { return nil }

        layoutGridDocumentView()
        view.layoutSubtreeIfNeeded()

        guard let centerWorld = worldViewportCenter() else { return nil }
        let centeredOrigin = CGPoint(
            x: centerWorld.x - tileSize.width / 2.0,
            y: centerWorld.y - tileSize.height / 2.0
        )
        let existingFrames = existingWorldFramesForPlacement(excluding: workspaceID)
        let centeredRect = CGRect(origin: centeredOrigin, size: tileSize)
        if !intersectsAny(centeredRect, with: existingFrames) {
            return centeredOrigin
        }

        let alignedCandidates = alignedCandidateOrigins(
            for: tileSize,
            around: existingFrames,
            gap: newDisplayPlacementGap
        )
        if let alignedBest = bestNonOverlappingOrigin(
            from: alignedCandidates,
            tileSize: tileSize,
            existingFrames: existingFrames,
            centerWorld: centerWorld
        ) {
            return alignedBest
        }

        let sampledCandidates = sampledCandidateOrigins(
            near: centerWorld,
            tileSize: tileSize,
            gap: newDisplayPlacementGap
        )
        if let sampledBest = bestNonOverlappingOrigin(
            from: sampledCandidates,
            tileSize: tileSize,
            existingFrames: existingFrames,
            centerWorld: centerWorld
        ) {
            return sampledBest
        }

        return centeredOrigin
    }

    private func worldViewportCenter() -> CGPoint? {
        let viewport = gridView.bounds.size
        guard viewport.width > 1, viewport.height > 1 else { return nil }
        let scale = max(0.01, gridView.cameraMagnification)
        return CGPoint(
            x: gridView.cameraOrigin.x + viewport.width / (2.0 * scale),
            y: gridView.cameraOrigin.y + viewport.height / (2.0 * scale)
        )
    }

    private func existingWorldFramesForPlacement(excluding workspaceID: UUID) -> [CGRect] {
        workspaceStore.workspaces.compactMap { workspace in
            guard workspace.id != workspaceID else { return nil }
            guard let frame = gridView.frameForWorkspaceInWorld(workspace.id) else { return nil }
            return frame
        }
    }

    private func alignedCandidateOrigins(for tileSize: CGSize, around frames: [CGRect], gap: CGFloat) -> [CGPoint] {
        var candidates: [CGPoint] = []
        for frame in frames {
            let leftX = frame.minX - tileSize.width - gap
            let rightX = frame.maxX + gap
            let bottomY = frame.minY - tileSize.height - gap
            let topY = frame.maxY + gap
            let alignedYs: [CGFloat] = [frame.minY, frame.midY - tileSize.height / 2.0, frame.maxY - tileSize.height]
            let alignedXs: [CGFloat] = [frame.minX, frame.midX - tileSize.width / 2.0, frame.maxX - tileSize.width]

            for y in alignedYs {
                candidates.append(CGPoint(x: leftX, y: y))
                candidates.append(CGPoint(x: rightX, y: y))
            }
            for x in alignedXs {
                candidates.append(CGPoint(x: x, y: bottomY))
                candidates.append(CGPoint(x: x, y: topY))
            }
        }
        return candidates
    }

    private func sampledCandidateOrigins(near center: CGPoint, tileSize: CGSize, gap: CGFloat) -> [CGPoint] {
        let stepX = max(tileSize.width + gap, 40.0)
        let stepY = max(tileSize.height + gap, 40.0)
        var candidates: [CGPoint] = []
        candidates.append(CGPoint(x: center.x - tileSize.width / 2.0, y: center.y - tileSize.height / 2.0))

        for radius in 1...8 {
            let r = CGFloat(radius)
            for ix in -radius...radius {
                for iy in -radius...radius {
                    if abs(ix) != radius, abs(iy) != radius { continue }
                    let x = center.x + CGFloat(ix) * stepX - tileSize.width / 2.0
                    let y = center.y + CGFloat(iy) * stepY - tileSize.height / 2.0
                    candidates.append(CGPoint(x: x, y: y))
                }
            }
            candidates.append(CGPoint(x: center.x + r * stepX - tileSize.width / 2.0, y: center.y - tileSize.height / 2.0))
            candidates.append(CGPoint(x: center.x - r * stepX - tileSize.width / 2.0, y: center.y - tileSize.height / 2.0))
            candidates.append(CGPoint(x: center.x - tileSize.width / 2.0, y: center.y + r * stepY - tileSize.height / 2.0))
            candidates.append(CGPoint(x: center.x - tileSize.width / 2.0, y: center.y - r * stepY - tileSize.height / 2.0))
        }
        return candidates
    }

    private func bestNonOverlappingOrigin(
        from candidates: [CGPoint],
        tileSize: CGSize,
        existingFrames: [CGRect],
        centerWorld: CGPoint
    ) -> CGPoint? {
        var bestOrigin: CGPoint?
        var bestScore = -CGFloat.greatestFiniteMagnitude
        var seen: Set<String> = []

        for origin in candidates {
            if !origin.x.isFinite || !origin.y.isFinite { continue }
            let key = "\(Int(origin.x.rounded())):\(Int(origin.y.rounded()))"
            if seen.contains(key) { continue }
            seen.insert(key)

            let rect = CGRect(origin: origin, size: tileSize)
            guard !intersectsAny(rect, with: existingFrames) else { continue }

            let score = placementScore(for: rect, existingFrames: existingFrames, centerWorld: centerWorld)
            if score > bestScore {
                bestScore = score
                bestOrigin = origin
            }
        }

        return bestOrigin
    }

    private func placementScore(for rect: CGRect, existingFrames: [CGRect], centerWorld: CGPoint) -> CGFloat {
        let clearance = minimumClearance(from: rect, to: existingFrames)
        let centerDistance = hypot(rect.midX - centerWorld.x, rect.midY - centerWorld.y)
        return clearance * 1000.0 - centerDistance
    }

    private func minimumClearance(from rect: CGRect, to frames: [CGRect]) -> CGFloat {
        guard !frames.isEmpty else { return 10_000.0 }
        return frames.map { frameDistance(rect, $0) }.min() ?? 0.0
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let dx = max(0.0, max(rhs.minX - lhs.maxX, lhs.minX - rhs.maxX))
        let dy = max(0.0, max(rhs.minY - lhs.maxY, lhs.minY - rhs.maxY))
        return hypot(dx, dy)
    }

    private func intersectsAny(_ rect: CGRect, with frames: [CGRect]) -> Bool {
        for frame in frames {
            if rect.intersects(frame) {
                return true
            }
        }
        return false
    }

    func beginShutdown(completion: @escaping () -> Void) {
        setTileStatus("Cleaning up displays...")
        immersiveTeleportWorkItem?.cancel()
        immersiveTeleportWorkItem = nil
        teardownWindowLevelMonitor()
        previewWindowController.closePreview()
        let snapshot = makeSnapshot()
        lifecycleQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion()
                }
                return
            }

            self.stateStore.flushNow(snapshot)
            self.streamManager.stopAll()
            self.displayManager.removeAllVirtualDisplays()
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    private func installSwipeMonitorsIfNeeded() {
        if localSwipeMonitor == nil {
            localSwipeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self else { return event }
                let consumed = self.handleNavigationEvent(event)
                return consumed ? nil : event
            }
        }
        if globalSwipeMonitor == nil {
            globalSwipeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                _ = self?.handleNavigationEvent(event)
            }
        }
    }

    private func installMagnificationMonitorIfNeeded() {
        if localMagnifyMonitor == nil {
            localMagnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify]) { [weak self] event in
                guard let self else { return event }
                let consumed = self.handleCanvasMagnify(event, requireUnfocusedWindow: false)
                return consumed ? nil : event
            }
        }
        guard globalMagnifyMonitor == nil else { return }
        globalMagnifyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.magnify]) { [weak self] event in
            DispatchQueue.main.async {
                _ = self?.handleCanvasMagnify(event, requireUnfocusedWindow: true)
            }
        }
    }

    private func installCanvasScrollMonitorsIfNeeded() {
        if localCanvasScrollMonitor == nil {
            localCanvasScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self else { return event }
                let consumed = self.handleCanvasScrollEvent(event, requireUnfocusedWindow: false)
                return consumed ? nil : event
            }
        }
        guard globalCanvasScrollMonitor == nil else { return }
        globalCanvasScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            DispatchQueue.main.async {
                _ = self?.handleCanvasScrollEvent(event, requireUnfocusedWindow: true)
            }
        }
    }

    private func installMouseMovementMonitorIfNeeded() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if localMouseMovementMonitor == nil {
            localMouseMovementMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                self?.updateSeamlessMousePassthroughIfNeeded()
                return event
            }
        }
        guard globalMouseMovementMonitor == nil else { return }
        globalMouseMovementMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateSeamlessMousePassthroughIfNeeded()
            }
        }
    }

    @discardableResult
    private func handleCanvasMagnify(_ event: NSEvent, requireUnfocusedWindow: Bool) -> Bool {
        guard currentLayoutMode == .canvas else { return false }
        guard !workspaceStore.workspaces.isEmpty else { return false }
        guard canInteractWithCanvasNavigation() else { return false }
        guard let window = view.window, window.isVisible else { return false }
        if requireUnfocusedWindow, isOrcvWindowFocused() {
            return false
        }
        let mouseInScreen = NSEvent.mouseLocation
        guard isPointerDirectlyOverWindow(window: window, screenPoint: mouseInScreen) else { return false }

        pendingScrollZoomDelta = 0.0
        let delta = event.magnification
        guard delta.isFinite, abs(delta) > 0.0001 else { return false }

        let mouseInWindow = window.convertPoint(fromScreen: mouseInScreen)
        let mouseInGrid = gridView.convert(mouseInWindow, from: nil)
        guard gridView.bounds.contains(mouseInGrid) else { return false }
        return applyCanvasZoom(magnificationDelta: delta, anchorViewPoint: mouseInGrid)
    }

    @discardableResult
    private func handleCanvasScrollEvent(_ event: NSEvent, requireUnfocusedWindow: Bool) -> Bool {
        guard currentLayoutMode == .canvas else { return false }
        guard !workspaceStore.workspaces.isEmpty else { return false }
        guard canInteractWithCanvasNavigation() else { return false }
        guard let window = view.window, window.isVisible else { return false }
        if requireUnfocusedWindow, isOrcvWindowFocused() {
            return false
        }

        let mouseInScreen = NSEvent.mouseLocation
        guard isPointerDirectlyOverWindow(window: window, screenPoint: mouseInScreen) else { return false }
        let mouseInWindow = window.convertPoint(fromScreen: mouseInScreen)
        let mouseInGrid = gridView.convert(mouseInWindow, from: nil)
        guard gridView.bounds.contains(mouseInGrid) else { return false }

        let rawDeltaX = event.scrollingDeltaX
        let rawDeltaY = event.scrollingDeltaY
        guard rawDeltaX.isFinite, rawDeltaY.isFinite else { return false }

        let normalizedX = event.hasPreciseScrollingDeltas ? rawDeltaX : rawDeltaX * 10.0
        let normalizedY = event.hasPreciseScrollingDeltas ? rawDeltaY : rawDeltaY * 10.0

        if shortcutManager.isZoomModifierActive(modifierFlags: event.modifierFlags) {
            let dominant = abs(normalizedY) >= abs(normalizedX) ? normalizedY : normalizedX
            guard abs(dominant) > 0.0 else { return false }
            let gain: CGFloat = event.hasPreciseScrollingDeltas ? 0.006 : 0.012
            let eventZoomDelta = dominant * gain
            guard eventZoomDelta.isFinite else { return false }

            pendingScrollZoomDelta += eventZoomDelta
            if abs(pendingScrollZoomDelta) < 0.00008 {
                // Consume tiny zoom gestures and accumulate until they become visible.
                return true
            }

            let magnificationDelta = max(-0.12, min(0.12, pendingScrollZoomDelta))
            pendingScrollZoomDelta = 0.0
            _ = applyCanvasZoom(magnificationDelta: magnificationDelta, anchorViewPoint: mouseInGrid)
            return true
        }

        pendingScrollZoomDelta = 0.0
        let shiftHeld = event.modifierFlags.contains(.shift)
        var panDeltaX = normalizedX
        var panDeltaY = normalizedY
        if shiftHeld {
            if shiftPanAxisLock == nil {
                shiftPanAxisLock = abs(panDeltaX) > abs(panDeltaY) ? .horizontal : .vertical
            }
            switch shiftPanAxisLock {
            case .horizontal:
                panDeltaY = 0
            case .vertical:
                panDeltaX = 0
            case .none:
                break
            }
        } else {
            shiftPanAxisLock = nil
        }

        if event.phase == .ended
            || event.phase == .cancelled
            || event.momentumPhase == .ended
            || event.momentumPhase == .cancelled {
            shiftPanAxisLock = nil
        }

        return applyCanvasPan(deltaX: panDeltaX, deltaY: panDeltaY)
    }

    @discardableResult
    private func applyCanvasZoom(magnificationDelta: CGFloat, anchorViewPoint: CGPoint) -> Bool {
        guard currentLayoutMode == .canvas else { return false }
        guard canInteractWithCanvasNavigation() else { return false }
        guard magnificationDelta.isFinite, abs(magnificationDelta) > 0.00001 else { return false }

        let currentMag = gridView.cameraMagnification
        let scaleFactor = max(0.05, 1.0 + magnificationDelta)
        let targetMag = currentMag * scaleFactor
        let clampedMag = max(minCanvasMagnification, min(maxCanvasMagnification, targetMag))
        guard abs(clampedMag - currentMag) > 0.00001 else { return false }

        let worldAtAnchor = CGPoint(
            x: gridView.cameraOrigin.x + (anchorViewPoint.x / currentMag),
            y: gridView.cameraOrigin.y + (anchorViewPoint.y / currentMag)
        )
        let newOrigin = CGPoint(
            x: worldAtAnchor.x - (anchorViewPoint.x / clampedMag),
            y: worldAtAnchor.y - (anchorViewPoint.y / clampedMag)
        )
        gridView.cameraMagnification = clampedMag
        gridView.cameraOrigin = newOrigin
        lastCanvasCamera = currentCanvasCameraState() ?? lastCanvasCamera
        scheduleCanvasCameraSaveDebounced()
        scheduleDisplayStreamRefresh()
        return true
    }

    @discardableResult
    private func applyCanvasPan(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        guard currentLayoutMode == .canvas else { return false }
        guard canInteractWithCanvasNavigation() else { return false }
        guard deltaX.isFinite, deltaY.isFinite else { return false }
        let scale = max(0.01, gridView.cameraMagnification)
        let worldDelta = CGPoint(x: deltaX / scale, y: deltaY / scale)
        guard abs(worldDelta.x) > 0.0001 || abs(worldDelta.y) > 0.0001 else { return false }

        gridView.cameraOrigin = CGPoint(
            x: gridView.cameraOrigin.x - worldDelta.x,
            y: gridView.cameraOrigin.y + worldDelta.y
        )
        lastCanvasCamera = currentCanvasCameraState() ?? lastCanvasCamera
        scheduleCanvasCameraSaveDebounced()
        scheduleDisplayStreamRefresh()
        return true
    }

    private func canInteractWithCanvasNavigation() -> Bool {
        !seamlessModeEnabled || seamlessFocusLockEnabled
    }

    private func installWindowLevelMonitorIfNeeded() {
        guard windowLevelPollingTimer == nil else { return }
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.refreshGridWindowLevelForPointerMapping()
            if self?.unlockFPSIfInteractingEnabled == true {
                self?.scheduleDisplayStreamRefresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        windowLevelPollingTimer = timer
    }

    private func teardownWindowLevelMonitor() {
        windowLevelPollingTimer?.invalidate()
        windowLevelPollingTimer = nil
        if let window = view.window {
            setGridWindowFloating(false, window: window)
        } else {
            isGridWindowFloating = false
        }
    }

    private func installSpaceFollowWindowMonitorIfNeeded() {
        guard spaceFollowWindowTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 90.0, repeats: true) { [weak self] _ in
            self?.updateSpaceFollowWindowIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        spaceFollowWindowTimer = timer
    }

    private func teardownSpaceFollowWindowMonitor() {
        spaceFollowWindowTimer?.invalidate()
        spaceFollowWindowTimer = nil
        lastSpaceFollowMouseScreenPoint = nil
        setMoveCursorActive(false)
    }

    private func updateSpaceFollowWindowIfNeeded() {
        guard let window = view.window, window.isVisible else {
            lastSpaceFollowMouseScreenPoint = nil
            setMoveCursorActive(false)
            return
        }
        if seamlessModeEnabled {
            lastSpaceFollowMouseScreenPoint = nil
            setMoveCursorActive(false)
            return
        }
        guard !previewWindowController.isPresenting else {
            lastSpaceFollowMouseScreenPoint = nil
            setMoveCursorActive(false)
            return
        }

        let mouseInScreen = NSEvent.mouseLocation
        let pointerDirectlyOverWindow = isPointerDirectlyOverWindow(window: window, screenPoint: mouseInScreen)
        let followShortcutActive = isWindowFollowShortcutActive()
        let canFollow = followShortcutActive && pointerDirectlyOverWindow
        setMoveCursorActive(followShortcutActive)

        guard canFollow else {
            lastSpaceFollowMouseScreenPoint = nil
            return
        }

        if let last = lastSpaceFollowMouseScreenPoint {
            let dx = mouseInScreen.x - last.x
            let dy = mouseInScreen.y - last.y
            if abs(dx) > 0.01 || abs(dy) > 0.01 {
                let newOrigin = CGPoint(x: window.frame.origin.x + dx, y: window.frame.origin.y + dy)
                window.setFrameOrigin(newOrigin)
            }
        }
        lastSpaceFollowMouseScreenPoint = mouseInScreen
    }

    private func isWindowFollowShortcutActive() -> Bool {
        if requireHoldingMoveShortcutEnabled {
            return shortcutManager.isWindowFollowShortcutActive()
        }
        return windowFollowToggleActive
    }

    private func setWindowFollowToggleActive(_ active: Bool) {
        guard windowFollowToggleActive != active else { return }
        windowFollowToggleActive = active
        if !active {
            lastSpaceFollowMouseScreenPoint = nil
        }
        updateSpaceFollowWindowIfNeeded()
    }

    private func setMoveCursorActive(_ active: Bool) {
        if active {
            if !moveCursorActive {
                moveCursorActive = true
                NSCursor.openHand.push()
            } else {
                // Reassert cursor; AppKit can reset it during mouse-move handling.
                NSCursor.openHand.set()
            }
        } else {
            guard moveCursorActive else { return }
            moveCursorActive = false
            NSCursor.pop()
        }
    }

    private func isPointerDirectlyOverWindow(window: NSWindow, screenPoint: CGPoint) -> Bool {
        let topWindowNumber = NSWindow.windowNumber(
            at: screenPoint,
            belowWindowWithWindowNumber: 0
        )
        guard topWindowNumber > 0 else { return false }
        return topWindowNumber == window.windowNumber
    }

    private func scheduleCanvasCameraSaveDebounced() {
        canvasCameraSaveDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scheduleStateSave()
        }
        canvasCameraSaveDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func refreshGridWindowLevelForPointerMapping() {
        guard let window = view.window else { return }

        if previewWindowController.isPresenting || window.styleMask.contains(.fullScreen) {
            setGridWindowFloating(false, window: window)
            return
        }

        if seamlessModeEnabled {
            setGridWindowFloating(true, window: window)
            return
        }

        if alwaysOnTopEnabled {
            setGridWindowFloating(true, window: window)
            return
        }

        setGridWindowFloating(shouldFloatGridWindowForMappedPointer(), window: window)
    }

    private func shouldFloatGridWindowForMappedPointer() -> Bool {
        let virtualWorkspaces = workspaceStore.workspaces.filter { $0.kind == .virtual }
        guard !virtualWorkspaces.isEmpty else { return false }

        for workspace in virtualWorkspaces {
            guard let tileFrame = gridView.frameForWorkspaceInScreen(workspace.id) else { continue }
            if pointerRouter.currentMouseMapsIntoTile(
                fromDisplayID: workspace.displayID,
                toTileScreenFrame: tileFrame
            ) {
                return true
            }
        }

        return false
    }

    private func setGridWindowFloating(_ shouldFloat: Bool, window: NSWindow) {
        guard shouldFloat != isGridWindowFloating else { return }
        window.level = shouldFloat ? .floating : .normal
        isGridWindowFloating = shouldFloat
    }

    private func handleNavigationEvent(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shortcutMods = mods.intersection([.control, .option, .command, .shift])
        if event.type == .keyDown {
            if let slot = digitSlotForNavigationEvent(event) {
                if shortcutManager.matchesJumpToSlotModifier(shortcutMods), (1...9).contains(slot) {
                    guard isOrcvWindowFocused() else { return false }
                    _ = jumpToDisplaySlot(slot)
                    return true
                }
                if shortcutManager.matchesSavepointModifier(shortcutMods) {
                    guard isOrcvWindowFocused() else { return false }
                    _ = saveCanvasSavepoint(slot: slot)
                    return true
                }
                if shortcutMods.isEmpty {
                    guard isOrcvWindowFocused() else { return false }
                    _ = recallCanvasSavepoint(slot: slot)
                    return true
                }
            }
        }

        let action = shortcutManager.action(for: event)
        if event.type == .keyDown, event.keyCode == 49, isOrcvWindowFocused(), action == nil {
            return true
        }
        guard let action else { return false }
        let windowFocused = isOrcvWindowFocused()
        if actionRequiresFocusedWindow(action), !windowFocused {
            return false
        }

        switch action {
        case .toggleTeleport:
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastTeleportTime < 0.12 {
                return false
            }
            lastTeleportTime = now
            menuToggleTeleport()
            return true
        case .newDisplay:
            handleNewDisplay()
            return true
        case .removeDisplay:
            handleRemoveHovered()
            return true
        case .fullscreenSelected:
            openFullscreenForHoveredWorkspace()
            return true
        case .jumpNextDisplay:
            menuJumpNextDisplay()
            return true
        case .jumpPreviousDisplay:
            menuJumpPreviousDisplay()
            return true
        case .windowFollowHold:
            guard !seamlessModeEnabled else { return false }
            if requireHoldingMoveShortcutEnabled {
                return true
            }
            guard isPointerWithinOrcvWindowBounds() || isOrcvWindowFocused() else { return false }
            setWindowFollowToggleActive(!windowFollowToggleActive)
            return true
        case .deselectTile:
            menuDeselectTile()
            return true
        case .hideWindow:
            guard isOrcvWindowFocused() else { return false }
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.toggleMainWindowVisibility()
            } else {
                NSApp.hide(nil)
            }
            return true
        case .navigateBack:
            guard isPointerWithinOrcvWindowBounds() else { return false }
            return navigateCameraBack()
        case .navigateForward:
            guard isPointerWithinOrcvWindowBounds() else { return false }
            return navigateCameraForward()
        case .toggleWindowFocus:
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.toggleOrcvFocus()
            } else {
                NSApp.activate(ignoringOtherApps: true)
                view.window?.makeKeyAndOrderFront(nil)
            }
            return true
        }
    }

    private func isPointerWithinOrcvWindowBounds() -> Bool {
        guard let window = view.window, window.isVisible else { return false }
        let mouseInScreen = NSEvent.mouseLocation
        return isPointerDirectlyOverWindow(window: window, screenPoint: mouseInScreen)
    }

    private func actionRequiresFocusedWindow(_ action: ShortcutAction) -> Bool {
        switch action {
        case .toggleTeleport, .windowFollowHold, .hideWindow, .navigateBack, .navigateForward, .removeDisplay, .toggleWindowFocus:
            return false
        case .newDisplay, .fullscreenSelected, .jumpNextDisplay, .jumpPreviousDisplay, .deselectTile:
            return true
        }
    }

    private func digitSlotForNavigationEvent(_ event: NSEvent) -> Int? {
        guard event.type == .keyDown else { return nil }
        switch event.keyCode {
        case 29, 82:
            return 0
        case 18, 83:
            return 1
        case 19, 84:
            return 2
        case 20, 85:
            return 3
        case 21, 86:
            return 4
        case 23, 87:
            return 5
        case 22, 88:
            return 6
        case 26, 89:
            return 7
        case 28, 91:
            return 8
        case 25, 92:
            return 9
        default:
            return nil
        }
    }

    private func isOrcvWindowFocused() -> Bool {
        guard NSApp.isActive, let window = view.window else { return false }
        return NSApp.keyWindow === window || NSApp.mainWindow === window
    }

    private func toggleTeleport() {
        let now = ProcessInfo.processInfo.systemUptime
        if now < suppressTeleportUntil {
            return
        }
        if previewWindowController.isPresenting || previewWindowController.window?.isVisible == true {
            immersiveTeleportWorkItem?.cancel()
            immersiveTeleportWorkItem = nil
            teleportBackFromPresentedPreviewIfNeeded()
            previewWindowController.closePreview()
            returnFocusToOrcvWindow()
            suppressTeleportUntil = now + 0.45
            return
        }
        if workspaceUnderCurrentMouseDisplay() != nil {
            teleportBackFromActiveWorkspace()
        } else {
            teleportIntoHoveredWorkspace()
        }
    }

    private func returnFocusToOrcvWindow() {
        guard let window = view.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func teleportBackFromActiveWorkspace() {
        guard let workspace = workspaceUnderCurrentMouseDisplay(),
              let frame = gridView.frameForWorkspaceInScreen(workspace.id) else { return }
        pointerRouter.teleportBack(
            fromDisplayID: workspace.displayID,
            toTileScreenFrame: frame
        )
    }

    private func teleportIntoHoveredWorkspace() {
        guard let window = view.window else { return }
        let mouseInScreen = NSEvent.mouseLocation
        let pointInWindow = window.convertPoint(fromScreen: mouseInScreen)
        let pointInGrid = gridView.convert(pointInWindow, from: nil)
        guard let hit = gridView.hitTestWorkspace(at: pointInGrid),
              let workspace = workspaceStore.workspace(with: hit.workspaceID) else { return }

        pointerRouter.teleportInto(
            workspace: workspace,
            pointInTile: hit.pointInTile,
            tileFrameInWindow: hit.frameInGrid
        )
        scheduleArrangementSync()
    }

    private func teleportBackFromPresentedPreviewIfNeeded() {
        guard let displayID = previewWindowController.presentedDisplayID else {
            teleportToOrcvWindowDisplayCenter()
            return
        }

        if let workspace = workspaceStore.workspaces.first(where: { $0.displayID == displayID }),
           let tileFrame = gridView.frameForWorkspaceInScreen(workspace.id) {
            pointerRouter.teleportBack(
                fromDisplayID: displayID,
                toTileScreenFrame: tileFrame
            )
        }

        if isMouseOnDisplay(displayID) {
            teleportToOrcvWindowDisplayCenter()
        }
    }

    private func isMouseOnDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        guard let mouseQuartz = CGEvent(source: nil)?.location else { return false }
        return displayIDs(at: mouseQuartz).contains(displayID)
    }

    private func teleportToOrcvWindowDisplayCenter() {
        if let screen = view.window?.screen,
           let displayID = displayID(for: screen) {
            pointerRouter.teleportToDisplay(displayID: displayID)
            return
        }
        if let fallbackScreen = NSScreen.main ?? NSScreen.screens.first,
           let displayID = displayID(for: fallbackScreen) {
            pointerRouter.teleportToDisplay(displayID: displayID)
        }
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func workspaceUnderCurrentMouseDisplay() -> Workspace? {
        guard let mouseQuartz = CGEvent(source: nil)?.location else { return nil }
        let displayIDs = displayIDs(at: mouseQuartz)
        guard !displayIDs.isEmpty else { return nil }
        let virtualByDisplayID = Dictionary(uniqueKeysWithValues: workspaceStore.workspaces
            .filter { $0.kind == .virtual }
            .map { ($0.displayID, $0) })
        for displayID in displayIDs {
            if let workspace = virtualByDisplayID[displayID] {
                return workspace
            }
        }
        return nil
    }

    private func displayIDs(at point: CGPoint) -> [CGDirectDisplayID] {
        DisplayQuery.displayIDs(at: point)
    }

    private func scheduleArrangementSync() {
        if view.window?.inLiveResize == true {
            pendingArrangementSyncAfterLiveResize = true
            arrangementDebounceWorkItem?.cancel()
            lastQueuedArrangementSignature = nil
            return
        }

        let signature = arrangementSignatureForCurrentGrid()
        if let signature {
            if signature == lastAppliedArrangementSignature {
                return
            }
            if signature == lastQueuedArrangementSignature, arrangementDebounceWorkItem != nil {
                return
            }
        }

        arrangementGeneration &+= 1
        let generation = arrangementGeneration
        lastQueuedArrangementSignature = signature

        arrangementDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.applyDisplayArrangementFromGrid(generation: generation, signatureHint: signature)
        }
        arrangementDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + arrangementDebounceInterval, execute: workItem)
    }

    private func applyDisplayArrangementFromGrid(generation: UInt64, signatureHint: UInt64?) {
        guard generation == arrangementGeneration else { return }
        if view.window?.inLiveResize == true {
            pendingArrangementSyncAfterLiveResize = true
            return
        }
        let finalOrigins = computeDisplayArrangementOriginsFromGrid()
        guard !finalOrigins.isEmpty else { return }
        guard !originsMatch(lhs: finalOrigins, rhs: lastAppliedOrigins) else {
            lastAppliedArrangementSignature = signatureHint
            lastQueuedArrangementSignature = nil
            return
        }

        arrangementApplyQueue.async { [weak self] in
            guard let self else { return }
            var shouldApply = false
            DispatchQueue.main.sync {
                shouldApply = (generation == self.arrangementGeneration)
            }
            guard shouldApply else { return }
            let didApply = self.displayManager.applyDisplayOrigins(finalOrigins)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard generation == self.arrangementGeneration else { return }
                self.lastQueuedArrangementSignature = nil
                guard didApply else { return }
                self.lastAppliedOrigins = finalOrigins
                self.lastAppliedArrangementSignature = signatureHint ?? self.arrangementSignatureForCurrentGrid()
            }
        }
    }

    private func applyDisplayArrangementImmediatelyIfNeeded() {
        let signature = arrangementSignatureForCurrentGrid()
        if let signature, signature == lastAppliedArrangementSignature {
            return
        }
        let finalOrigins = computeDisplayArrangementOriginsFromGrid()
        guard !finalOrigins.isEmpty else { return }
        guard !originsMatch(lhs: finalOrigins, rhs: lastAppliedOrigins) else {
            lastAppliedArrangementSignature = signature
            return
        }
        if displayManager.applyDisplayOrigins(finalOrigins) {
            lastAppliedOrigins = finalOrigins
            lastAppliedArrangementSignature = signature
        }
    }

    private func computeDisplayArrangementOriginsFromGrid() -> [CGDirectDisplayID: CGPoint] {
        let virtualWorkspaces = workspaceStore.workspaces.filter { $0.kind == .virtual }
        guard !virtualWorkspaces.isEmpty else { return [:] }

        struct Entry {
            let displayID: CGDirectDisplayID
            let tileFrameWorld: CGRect
            let displayBounds: CGRect
        }

        let entries: [Entry] = virtualWorkspaces.compactMap { workspace in
            guard let tileFrame = gridView.frameForWorkspaceInWorld(workspace.id) else { return nil }
            let displayBounds = CGDisplayBounds(workspace.displayID)
            guard tileFrame.width > 1, tileFrame.height > 1,
                  displayBounds.width > 1, displayBounds.height > 1 else {
                return nil
            }
            return Entry(displayID: workspace.displayID, tileFrameWorld: tileFrame, displayBounds: displayBounds)
        }

        guard !entries.isEmpty else { return [:] }

        var finalOrigins: [CGDirectDisplayID: CGPoint] = [:]
        let tileMinX = entries.map { $0.tileFrameWorld.minX }.min() ?? 0
        let tileTopY = entries.map { $0.tileFrameWorld.maxY }.max() ?? 0
        let topLeftYForEntry: (Entry) -> CGFloat = { entry in
            tileTopY - entry.tileFrameWorld.maxY
        }
        let tileMinY = entries.map(topLeftYForEntry).min() ?? 0
        let displayMinX = entries.map { $0.displayBounds.minX }.min() ?? 0
        let displayMinY = entries.map { $0.displayBounds.minY }.min() ?? 0

        let scaleCandidates = entries.flatMap { entry in
            [entry.displayBounds.width / entry.tileFrameWorld.width,
             entry.displayBounds.height / entry.tileFrameWorld.height]
        }
        let scale = median(of: scaleCandidates)
        guard scale > 0 else { return [:] }

        for entry in entries {
            let mappedX = displayMinX + (entry.tileFrameWorld.minX - tileMinX) * scale
            let mappedY = displayMinY + (topLeftYForEntry(entry) - tileMinY) * scale
            finalOrigins[entry.displayID] = CGPoint(x: mappedX.rounded(), y: mappedY.rounded())
        }
        return finalOrigins
    }

    private func arrangementSignatureForCurrentGrid() -> UInt64? {
        let virtualWorkspaces = workspaceStore.workspaces.filter { $0.kind == .virtual }
        guard !virtualWorkspaces.isEmpty else { return nil }
        var hasher = Hasher()
        var included = 0
        for workspace in virtualWorkspaces {
            guard let frame = gridView.frameForWorkspaceInWorld(workspace.id) else { continue }
            let bounds = CGDisplayBounds(workspace.displayID)
            hasher.combine(Int(workspace.displayID))
            hasher.combine(Int((frame.minX * 10.0).rounded()))
            hasher.combine(Int((frame.minY * 10.0).rounded()))
            hasher.combine(Int((frame.width * 10.0).rounded()))
            hasher.combine(Int((frame.height * 10.0).rounded()))
            hasher.combine(Int(bounds.minX.rounded()))
            hasher.combine(Int(bounds.minY.rounded()))
            hasher.combine(Int(bounds.width.rounded()))
            hasher.combine(Int(bounds.height.rounded()))
            included += 1
        }
        guard included > 0 else { return nil }
        hasher.combine(included)
        let signed = Int64(hasher.finalize())
        return UInt64(bitPattern: signed)
    }

    private func originsMatch(lhs: [CGDirectDisplayID: CGPoint], rhs: [CGDirectDisplayID: CGPoint]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (displayID, l) in lhs {
            guard let r = rhs[displayID] else { return false }
            if abs(l.x - r.x) > 1.0 || abs(l.y - r.y) > 1.0 {
                return false
            }
        }
        return true
    }

    private func layoutGridDocumentView() {
        gridView.needsLayout = true
        gridView.needsDisplay = true
    }

    private func median(of values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }

    private func openFullscreenForHoveredWorkspace() {
        immersiveTeleportWorkItem?.cancel()
        immersiveTeleportWorkItem = nil

        if previewWindowController.isPresenting {
            previewWindowController.closePreview()
            refreshGridWindowLevelForPointerMapping()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastImmersiveToggleTime < 0.16 {
            return
        }
        lastImmersiveToggleTime = now

        guard let target = hoveredWorkspaceTargetForFullscreen() else {
            NSSound.beep()
            return
        }

        previewWindowController.presentImmersive(for: target.workspace, on: view.window?.screen)
        refreshGridWindowLevelForPointerMapping()
        pointerRouter.teleportToDisplay(displayID: target.workspace.displayID, normalized: target.normalizedPoint)
        let delayedTeleport = DispatchWorkItem { [weak self] in
            self?.pointerRouter.teleportToDisplay(
                displayID: target.workspace.displayID,
                normalized: target.normalizedPoint
            )
        }
        immersiveTeleportWorkItem = delayedTeleport
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: delayedTeleport)
    }

    private struct FullscreenTarget {
        let workspace: Workspace
        let normalizedPoint: CGPoint
    }

    private func hoveredWorkspaceTargetForFullscreen() -> FullscreenTarget? {
        guard let window = view.window else { return nil }
        let mouseInScreen = NSEvent.mouseLocation
        if isPointerDirectlyOverWindow(window: window, screenPoint: mouseInScreen) {
            let pointInWindow = window.convertPoint(fromScreen: mouseInScreen)
            let pointInGrid = gridView.convert(pointInWindow, from: nil)
            guard let hit = gridView.hitTestWorkspace(at: pointInGrid),
                  let workspace = workspaceStore.workspace(with: hit.workspaceID),
                  workspace.kind == .virtual else {
                return nil
            }
            let tileRect = CGRect(origin: .zero, size: hit.frameInGrid.size)
            let normalizedPoint = PointerMath.normalizedPoint(
                for: hit.pointInTile,
                in: tileRect,
                sourceYFlipped: false
            ) ?? CGPoint(x: 0.5, y: 0.5)
            return FullscreenTarget(workspace: workspace, normalizedPoint: normalizedPoint)
        }

        guard let workspace = workspaceUnderCurrentMouseDisplay(),
              workspace.kind == .virtual,
              let mouseQuartz = CGEvent(source: nil)?.location else {
            return nil
        }
        let displayBounds = CGDisplayBounds(workspace.displayID)
        let normalizedPoint = PointerMath.normalizedPoint(
            for: mouseQuartz,
            in: displayBounds,
            sourceYFlipped: true
        ) ?? CGPoint(x: 0.5, y: 0.5)
        return FullscreenTarget(workspace: workspace, normalizedPoint: normalizedPoint)
    }

    private func maybeRefreshDisplayPixelSizeFromSystem(displayID: CGDirectDisplayID, surface: IOSurface) {
        let now = ProcessInfo.processInfo.systemUptime
        let lastProbe = lastDisplayModeProbeTime[displayID] ?? 0
        guard now - lastProbe >= 0.35 else { return }
        lastDisplayModeProbeTime[displayID] = now

        let fallbackSize = CGSize(
            width: CGFloat(IOSurfaceGetWidth(surface)),
            height: CGFloat(IOSurfaceGetHeight(surface))
        )
        let pixelSize = systemDisplayPixelSize(for: displayID) ?? fallbackSize
        guard pixelSize.width > 1, pixelSize.height > 1 else { return }

        guard workspaceStore.updateDisplayPixelSize(displayID: displayID, pixelSize: pixelSize) != nil else {
            return
        }

        scheduleDisplayStreamRefresh(immediate: true, force: true)
        scheduleArrangementSync()
    }

    private func systemDisplayPixelSize(for displayID: CGDirectDisplayID) -> CGSize? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        let width = CGFloat(mode.pixelWidth)
        let height = CGFloat(mode.pixelHeight)
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    private func flushPendingArrangementSyncAfterLiveResizeIfNeeded() {
        guard pendingArrangementSyncAfterLiveResize else { return }
        guard view.window?.inLiveResize != true else { return }
        pendingArrangementSyncAfterLiveResize = false
        scheduleArrangementSync()
    }

    private func applyInteractionMode() {
        applyWindowPresentationPreferences()
        if gridView.cameraMagnification < minCanvasMagnification || gridView.cameraMagnification > maxCanvasMagnification {
            gridView.cameraMagnification = 1.0
        }
    }

    private func applyWindowPresentationPreferences() {
        if !seamlessModeEnabled {
            seamlessFocusLockEnabled = false
        }
        canvasBackdropView.isHidden = seamlessModeEnabled
        gridView.sharpCornersEnabled = sharpCornersPreferenceEnabled || seamlessModeEnabled
        seamlessFocusBorderView.isHidden = !(seamlessModeEnabled && seamlessFocusLockEnabled)
        if seamlessModeEnabled {
            setWindowFollowToggleActive(false)
        }
        updateSeamlessMousePassthroughIfNeeded()
        onWindowPresentationChange?()
    }

    private func setSeamlessModeEnabled(_ enabled: Bool, scheduleSave: Bool = true) {
        guard seamlessModeEnabled != enabled else { return }
        seamlessModeEnabled = enabled
        if !enabled {
            seamlessFocusLockEnabled = false
        }
        applyWindowPresentationPreferences()
        refreshGridWindowLevelForPointerMapping()
        if scheduleSave {
            scheduleStateSave()
        }
    }

    private func updateSeamlessMousePassthroughIfNeeded() {
        guard let window = view.window else { return }
        let shouldIgnoreMouseEvents: Bool
        if seamlessModeEnabled {
            if seamlessFocusLockEnabled {
                shouldIgnoreMouseEvents = false
            } else if !window.isVisible || previewWindowController.isPresenting || window.styleMask.contains(.fullScreen) {
                shouldIgnoreMouseEvents = true
            } else {
                shouldIgnoreMouseEvents = !isMouseOverInteractiveWorkspaceTile(screenPoint: NSEvent.mouseLocation)
            }
        } else {
            shouldIgnoreMouseEvents = false
        }

        guard window.ignoresMouseEvents != shouldIgnoreMouseEvents else { return }
        window.ignoresMouseEvents = shouldIgnoreMouseEvents
    }

    private func isMouseOverInteractiveWorkspaceTile(screenPoint: CGPoint) -> Bool {
        guard let window = view.window, window.isVisible else { return false }
        let pointInWindow = window.convertPoint(fromScreen: screenPoint)
        let pointInGrid = gridView.convert(pointInWindow, from: nil)
        return gridView.hitTestWorkspace(at: pointInGrid) != nil
    }

    private func consumeSeamlessFocusLockClick() -> Bool {
        guard seamlessFocusLockEnabled else { return false }
        setSeamlessFocusLockEnabled(false)
        return true
    }

    private func centerCanvasViewport() {
        guard currentLayoutMode == .canvas else { return }
        let viewportSize = gridView.bounds.size
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }
        let targetOrigin = gridView.canvasInitialViewportOrigin(for: viewportSize)
        gridView.cameraOrigin = targetOrigin
        if let camera = currentCanvasCameraState() { lastCanvasCamera = camera }
        scheduleDisplayStreamRefresh()
    }

    private func currentCanvasCameraState() -> CanvasCameraState? {
        guard currentLayoutMode == .canvas else { return nil }
        let mag = gridView.cameraMagnification
        guard mag.isFinite, mag > 0 else { return nil }
        let origin = gridView.cameraOrigin
        guard origin.x.isFinite, origin.y.isFinite else { return nil }
        return CanvasCameraState(magnification: mag, origin: origin)
    }

    private func applyCanvasCamera(_ camera: CanvasCameraState) {
        guard currentLayoutMode == .canvas else { return }
        let clampedMag = max(minCanvasMagnification, min(maxCanvasMagnification, camera.magnification))
        gridView.cameraMagnification = clampedMag
        gridView.cameraOrigin = camera.origin
        lastCanvasCamera = CanvasCameraState(magnification: clampedMag, origin: camera.origin)
        scheduleDisplayStreamRefresh()
    }

    private func jumpToDisplaySlot(_ slot: Int) -> Bool {
        guard (1...9).contains(slot) else { return false }
        let workspaces = workspaceStore.workspaces
        let index = slot - 1
        guard index >= 0, index < workspaces.count else { return false }
        let sourceWorkspaceID = workspaceStore.focusedWorkspaceID
        let target = workspaces[index]
        hasUsedAdjacentJumpSinceBootstrap = true
        workspaceStore.selectOnly(workspaceID: target.id)
        return jumpCameraToWorkspace(
            workspaceID: target.id,
            fitWidth: !preserveSizeOnSlotJumpEnabled,
            alignTopLeft: !centerTileOnJumpEnabled,
            preserveViewportOffsetFromWorkspaceID: preserveSizeOnSlotJumpEnabled ? sourceWorkspaceID : nil
        )
    }

    private func jumpToAdjacentDisplay(step: Int) -> Bool {
        let workspaces = workspaceStore.workspaces
        guard !workspaces.isEmpty else { return false }
        guard step != 0 else { return false }

        if !hasUsedAdjacentJumpSinceBootstrap {
            let sourceWorkspaceID = workspaceStore.focusedWorkspaceID
            let target = step > 0 ? workspaces[0] : workspaces[workspaces.count - 1]
            hasUsedAdjacentJumpSinceBootstrap = true
            workspaceStore.selectOnly(workspaceID: target.id)
            return jumpCameraToWorkspace(
                workspaceID: target.id,
                fitWidth: !preserveSizeOnSlotJumpEnabled,
                alignTopLeft: !centerTileOnJumpEnabled,
                preserveViewportOffsetFromWorkspaceID: preserveSizeOnSlotJumpEnabled ? sourceWorkspaceID : nil
            )
        }

        let sourceWorkspaceID = workspaceStore.focusedWorkspaceID
        let currentIndex = workspaceStore.focusedWorkspaceID
            .flatMap { focusedID in workspaces.firstIndex(where: { $0.id == focusedID }) } ?? 0
        let count = workspaces.count
        let wrappedIndex = ((currentIndex + step) % count + count) % count
        let target = workspaces[wrappedIndex]
        hasUsedAdjacentJumpSinceBootstrap = true
        workspaceStore.selectOnly(workspaceID: target.id)
        return jumpCameraToWorkspace(
            workspaceID: target.id,
            fitWidth: !preserveSizeOnSlotJumpEnabled,
            alignTopLeft: !centerTileOnJumpEnabled,
            preserveViewportOffsetFromWorkspaceID: preserveSizeOnSlotJumpEnabled ? sourceWorkspaceID : nil
        )
    }

    private func jumpCameraToWorkspace(
        workspaceID: UUID,
        fitWidth: Bool,
        alignTopLeft: Bool = false,
        preserveViewportOffsetFromWorkspaceID: UUID? = nil,
        pushHistory: Bool = true
    ) -> Bool {
        guard currentLayoutMode == .canvas else { return false }
        if pushHistory && !isNavigatingHistory {
            pushCameraHistory()
        }
        layoutGridDocumentView()
        view.layoutSubtreeIfNeeded()

        guard let worldFrame = gridView.frameForWorkspaceInWorld(workspaceID) else { return false }
        let viewport = gridView.bounds.size
        guard viewport.width > 1, viewport.height > 1 else { return false }

        var magnification = gridView.cameraMagnification
        if fitWidth {
            let desiredWidth = max(1.0, viewport.width)
            magnification = desiredWidth / max(1.0, worldFrame.width)
            magnification = max(minCanvasMagnification, min(maxCanvasMagnification, magnification))
        }
        let safeMag = max(minCanvasMagnification, min(maxCanvasMagnification, magnification))
        let newOrigin: CGPoint
        if !fitWidth,
           let sourceWorkspaceID = preserveViewportOffsetFromWorkspaceID,
           let sourceFrame = gridView.frameForWorkspaceInWorld(sourceWorkspaceID) {
            let relativeOffset = CGPoint(
                x: gridView.cameraOrigin.x - sourceFrame.minX,
                y: gridView.cameraOrigin.y - sourceFrame.minY
            )
            newOrigin = CGPoint(
                x: worldFrame.minX + relativeOffset.x,
                y: worldFrame.minY + relativeOffset.y
            )
        } else if alignTopLeft {
            newOrigin = CGPoint(
                x: worldFrame.minX,
                y: worldFrame.maxY - viewport.height / safeMag
            )
        } else {
            newOrigin = CGPoint(
                x: worldFrame.midX - viewport.width / (2.0 * safeMag),
                y: worldFrame.midY - viewport.height / (2.0 * safeMag)
            )
        }

        gridView.cameraMagnification = safeMag
        gridView.cameraOrigin = newOrigin
        lastCanvasCamera = currentCanvasCameraState() ?? lastCanvasCamera
        scheduleCanvasCameraSaveDebounced()
        return true
    }

    private func pushCameraHistory() {
        guard let entry = currentCameraHistoryEntry() else { return }
        // Skip if identical to current top of stack.
        if let last = cameraHistory.last,
           cameraHistoryCursor == cameraHistory.count - 1,
           !historyEntriesDiffer(last, entry) {
            return
        }
        // Truncate any forward history
        if cameraHistoryCursor < cameraHistory.count - 1 {
            cameraHistory.removeSubrange((cameraHistoryCursor + 1)...)
        }
        cameraHistory.append(entry)
        // Cap at limit
        if cameraHistory.count > maxCameraHistoryEntries {
            cameraHistory.removeFirst(cameraHistory.count - maxCameraHistoryEntries)
        }
        cameraHistoryCursor = cameraHistory.count - 1
    }

    private func currentCameraHistoryEntry() -> CameraHistoryEntry? {
        guard let camera = currentCanvasCameraState() ?? lastCanvasCamera else { return nil }
        return CameraHistoryEntry(camera: camera, windowFrame: view.window?.frame)
    }

    private func historyEntriesDiffer(_ lhs: CameraHistoryEntry, _ rhs: CameraHistoryEntry) -> Bool {
        if cameraStatesDiffer(lhs.camera, rhs.camera) {
            return true
        }
        switch (lhs.windowFrame, rhs.windowFrame) {
        case (nil, nil):
            return false
        case let (.some(a), .some(b)):
            return windowFramesDiffer(a, b)
        default:
            return true
        }
    }

    /// Sync live camera/window state into history before Back navigation.
    /// If user edited state after going Back, this creates a new branch tip.
    private func syncCurrentStateIntoHistoryForBackNavigation() {
        guard let current = currentCameraHistoryEntry() else { return }
        guard !cameraHistory.isEmpty else {
            cameraHistory = [current]
            cameraHistoryCursor = 0
            return
        }

        if cameraHistoryCursor < 0 || cameraHistoryCursor >= cameraHistory.count {
            cameraHistory = [current]
            cameraHistoryCursor = 0
            return
        }

        if cameraHistoryCursor < cameraHistory.count - 1 {
            let cursorEntry = cameraHistory[cameraHistoryCursor]
            guard historyEntriesDiffer(cursorEntry, current) else { return }
            cameraHistory.removeSubrange((cameraHistoryCursor + 1)...)
            cameraHistory.append(current)
        } else {
            guard let last = cameraHistory.last, historyEntriesDiffer(last, current) else { return }
            cameraHistory.append(current)
        }

        if cameraHistory.count > maxCameraHistoryEntries {
            cameraHistory.removeFirst(cameraHistory.count - maxCameraHistoryEntries)
        }
        cameraHistoryCursor = cameraHistory.count - 1
    }

    private func seedCameraHistoryIfNeeded() {
        guard cameraHistory.isEmpty else { return }
        pushCameraHistory()
    }

    private func navigateCameraBack() -> Bool {
        syncCurrentStateIntoHistoryForBackNavigation()
        guard cameraHistoryCursor >= 0, !cameraHistory.isEmpty else { return false }
        guard cameraHistoryCursor > 0 else { return false }
        cameraHistoryCursor -= 1
        isNavigatingHistory = true
        applyCameraHistoryEntry(cameraHistory[cameraHistoryCursor])
        isNavigatingHistory = false
        scheduleStateSave()
        return true
    }

    private func navigateCameraForward() -> Bool {
        guard cameraHistoryCursor < cameraHistory.count - 1 else { return false }
        cameraHistoryCursor += 1
        isNavigatingHistory = true
        applyCameraHistoryEntry(cameraHistory[cameraHistoryCursor])
        isNavigatingHistory = false
        scheduleStateSave()
        return true
    }

    private func applyCameraHistoryEntry(_ entry: CameraHistoryEntry) {
        if let window = view.window, let frame = entry.windowFrame, frame != window.frame {
            suppressWindowResizeUndoRegistration = true
            suppressProgrammaticWindowResizeCameraAdjustment = true
            window.setFrame(frame, display: true, animate: false)
            lastObservedWindowFrame = frame
            suppressProgrammaticWindowResizeCameraAdjustment = false
            suppressWindowResizeUndoRegistration = false
        }
        applyCanvasCamera(entry.camera)
    }

    private func ensureVisibleWorkspaceAfterBootstrap() {
        guard currentLayoutMode == .canvas else { return }
        guard !workspaceStore.workspaces.isEmpty else { return }
        layoutGridDocumentView()
        view.layoutSubtreeIfNeeded()

        let viewport = gridView.bounds
        guard viewport.width > 1, viewport.height > 1 else { return }
        let isAnyWorkspaceVisible = workspaceStore.workspaces.contains { workspace in
            guard let frame = gridView.frameForWorkspaceInGrid(workspace.id) else { return false }
            return frame.intersects(viewport)
        }
        guard !isAnyWorkspaceVisible else { return }

        let targetID = workspaceStore.focusedWorkspaceID ?? workspaceStore.workspaces.first?.id
        guard let targetID else { return }
        _ = jumpCameraToWorkspace(
            workspaceID: targetID,
            fitWidth: true,
            alignTopLeft: !centerTileOnJumpEnabled,
            pushHistory: false
        )
    }

    private func saveCanvasSavepoint(slot: Int) -> Bool {
        guard (0...9).contains(slot) else { return false }
        guard let camera = (currentLayoutMode == .canvas ? currentCanvasCameraState() : nil)
            ?? lastCanvasCamera
            ?? defaultCanvasCameraState() else { return false }

        layoutGridDocumentView()
        view.layoutSubtreeIfNeeded()
        materializeUnpositionedCanvasOriginsIfNeeded()

        let anchor = resolvedSavepointAnchor(for: camera, preferredReferenceID: savepointReferenceTile())
        let ref = anchor?.id
        let offset = anchor?.offset

        let savepoint = CanvasSavepoint(
            camera: camera,
            windowFrame: view.window?.frame,
            referenceTileID: ref,
            cameraOffsetFromTile: offset,
            seamlessModeEnabled: seamlessModeEnabled
        )
        canvasSavepoints[slot] = savepoint
        lastCanvasCamera = camera
        scheduleStateSave()
        return true
    }

    /// Find the most-visible tile, breaking ties by top-left position.
    /// If no tile is visible, fall back to focused tile (or first tile) so
    /// savepoints still get a stable relative anchor.
    private func savepointReferenceTile() -> UUID? {
        let viewport = gridView.bounds
        guard viewport.width > 1, viewport.height > 1 else { return nil }

        var best: (id: UUID, visibleArea: CGFloat, origin: CGPoint)?
        for workspace in workspaceStore.workspaces {
            guard let viewportFrame = gridView.frameForWorkspaceInGrid(workspace.id) else { continue }
            let intersection = viewportFrame.intersection(viewport)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            let origin = workspace.canvasOrigin ?? .zero
            if let current = best {
                if area > current.visibleArea + 1.0 {
                    best = (workspace.id, area, origin)
                } else if abs(area - current.visibleArea) <= 1.0 {
                    // Tie-break: prefer top-left-most (larger Y = higher in AppKit).
                    if origin.y > current.origin.y + 1.0
                        || (abs(origin.y - current.origin.y) <= 1.0 && origin.x < current.origin.x) {
                        best = (workspace.id, area, origin)
                    }
                }
            } else {
                best = (workspace.id, area, origin)
            }
        }
        if let bestID = best?.id {
            return bestID
        }
        if let focusedID = workspaceStore.focusedWorkspaceID,
           workspaceStore.workspace(with: focusedID) != nil {
            return focusedID
        }
        return workspaceStore.workspaces.first?.id
    }

    private func recallCanvasSavepoint(slot: Int) -> Bool {
        guard (0...9).contains(slot), let savepoint = canvasSavepoints[slot] else { return false }
        if !isNavigatingHistory {
            pushCameraHistory()
        }

        setSeamlessModeEnabled(savepoint.seamlessModeEnabled, scheduleSave: false)

        if !savepoint.seamlessModeEnabled,
           restoreWindowFrameOnSavepointRecallEnabled,
           let window = view.window,
           let targetFrame = savepoint.windowFrame {
            suppressWindowResizeUndoRegistration = true
            suppressProgrammaticWindowResizeCameraAdjustment = true
            window.setFrame(targetFrame, display: true, animate: false)
            lastObservedWindowFrame = targetFrame
            suppressProgrammaticWindowResizeCameraAdjustment = false
            suppressWindowResizeUndoRegistration = false
        }

        var resolvedCamera = savepoint.camera
        if let refID = savepoint.referenceTileID,
           let offset = savepoint.cameraOffsetFromTile,
           let currentOrigin = workspaceStore.workspace(with: refID)?.canvasOrigin
            ?? gridView.frameForWorkspaceInWorld(refID)?.origin {
            resolvedCamera = CanvasCameraState(
                magnification: savepoint.camera.magnification,
                origin: CGPoint(
                    x: currentOrigin.x + offset.x,
                    y: currentOrigin.y + offset.y
                )
            )
        }

        lastCanvasCamera = resolvedCamera
        applyCanvasCamera(resolvedCamera)
        scheduleStateSave()
        return true
    }

    private func defaultCanvasCameraState() -> CanvasCameraState? {
        let viewport = gridView.bounds.size
        guard viewport.width > 1, viewport.height > 1 else { return nil }
        let origin = gridView.canvasInitialViewportOrigin(for: viewport)
        guard origin.x.isFinite, origin.y.isFinite else { return nil }
        return CanvasCameraState(magnification: 1.0, origin: origin)
    }

    private func persistedCanvasSavepoints() -> [String: PersistedWorkspaceState.CameraBookmark]? {
        guard !canvasSavepoints.isEmpty else { return nil }
        let virtualWorkspaceIDs = workspaceStore.workspaces
            .filter { $0.kind == .virtual }
            .map(\.id)
        var encoded: [String: PersistedWorkspaceState.CameraBookmark] = [:]
        for (slot, savepoint) in canvasSavepoints where (0...9).contains(slot) {
            let frame = savepoint.windowFrame
            let refSerial: UInt32?
            let refIndex: Int?
            if let refID = savepoint.referenceTileID,
               let workspace = workspaceStore.workspace(with: refID) {
                refSerial = displayManager.virtualDisplaySerial(for: workspace.displayID)
                refIndex = virtualWorkspaceIDs.firstIndex(of: refID)
            } else {
                refSerial = nil
                refIndex = nil
            }
            encoded[String(slot)] = PersistedWorkspaceState.CameraBookmark(
                magnification: Double(savepoint.camera.magnification),
                offsetX: Double(savepoint.camera.origin.x),
                offsetY: Double(savepoint.camera.origin.y),
                windowX: frame.map { Double($0.origin.x) },
                windowY: frame.map { Double($0.origin.y) },
                windowWidth: frame.map { Double($0.size.width) },
                windowHeight: frame.map { Double($0.size.height) },
                referenceTileSerial: refSerial,
                referenceTileIndex: refIndex,
                tileOffsetX: savepoint.cameraOffsetFromTile.map { Double($0.x) },
                tileOffsetY: savepoint.cameraOffsetFromTile.map { Double($0.y) },
                seamlessMode: savepoint.seamlessModeEnabled ? true : nil
            )
        }
        return encoded.isEmpty ? nil : encoded
    }

    private func resolvedSavepointAnchor(
        for camera: CanvasCameraState,
        preferredReferenceID: UUID?
    ) -> (id: UUID, offset: CGPoint)? {
        var candidateIDs: [UUID] = []
        if let preferredReferenceID {
            candidateIDs.append(preferredReferenceID)
        }
        if let visibleReference = savepointReferenceTile(),
           !candidateIDs.contains(visibleReference) {
            candidateIDs.append(visibleReference)
        }
        if let focusedID = workspaceStore.focusedWorkspaceID,
           !candidateIDs.contains(focusedID) {
            candidateIDs.append(focusedID)
        }
        for workspace in workspaceStore.workspaces where !candidateIDs.contains(workspace.id) {
            candidateIDs.append(workspace.id)
        }

        for id in candidateIDs {
            if let origin = workspaceStore.workspace(with: id)?.canvasOrigin
                ?? gridView.frameForWorkspaceInWorld(id)?.origin {
                return (
                    id: id,
                    offset: CGPoint(
                        x: camera.origin.x - origin.x,
                        y: camera.origin.y - origin.y
                    )
                )
            }
        }
        return nil
    }

    private func restoredCanvasSavepoints(
        from persisted: PersistedWorkspaceState,
        serialToID: [UInt32: UUID],
        indexToID: [UUID]
    ) -> [Int: CanvasSavepoint] {
        guard let raw = persisted.canvasSavepoints, !raw.isEmpty else { return [:] }
        let workspaceIDBySerial = serialToID

        var decoded: [Int: CanvasSavepoint] = [:]
        for (slotKey, bookmark) in raw {
            guard let slot = Int(slotKey), (0...9).contains(slot) else { continue }
            let magnification = CGFloat(bookmark.magnification)
            let x = CGFloat(bookmark.offsetX)
            let y = CGFloat(bookmark.offsetY)
            guard magnification.isFinite, magnification > 0, x.isFinite, y.isFinite else { continue }
            let windowFrame: CGRect?
            if let wx = bookmark.windowX,
               let wy = bookmark.windowY,
               let ww = bookmark.windowWidth,
               let wh = bookmark.windowHeight,
               wx.isFinite, wy.isFinite, ww.isFinite, wh.isFinite, ww > 1, wh > 1 {
                windowFrame = CGRect(x: wx, y: wy, width: ww, height: wh)
            } else {
                windowFrame = nil
            }
            let camera = CanvasCameraState(
                magnification: magnification,
                origin: CGPoint(x: x, y: y)
            )
            let tileOffset: CGPoint? = {
                guard let tx = bookmark.tileOffsetX, let ty = bookmark.tileOffsetY,
                      tx.isFinite, ty.isFinite else {
                    return nil
                }
                return CGPoint(x: tx, y: ty)
            }()
            let referenceTileID: UUID? = {
                if let serial = bookmark.referenceTileSerial,
                   let id = workspaceIDBySerial[serial] {
                    return id
                }
                if let idx = bookmark.referenceTileIndex,
                   idx >= 0, idx < indexToID.count {
                    return indexToID[idx]
                }
                return nil
            }()
            let resolvedOffset: CGPoint?
            if referenceTileID != nil {
                resolvedOffset = tileOffset
            } else {
                resolvedOffset = nil
            }
            decoded[slot] = CanvasSavepoint(
                camera: camera,
                windowFrame: windowFrame,
                referenceTileID: referenceTileID,
                cameraOffsetFromTile: resolvedOffset,
                seamlessModeEnabled: bookmark.seamlessMode ?? false
            )
        }
        return decoded
    }

    private func registerOrderUndo(from before: [UUID], to after: [UUID], actionName: String) {
        guard before != after else { return }
        actionUndoManager.registerUndo(withTarget: self) { target in
            target.applyOrderWithUndo(
                targetOrder: before,
                inverseOrder: after,
                actionName: actionName
            )
        }
        actionUndoManager.setActionName(actionName)
    }

    private func registerWindowResizeUndo(
        from before: CGRect,
        to after: CGRect,
        beforeCamera: CanvasCameraState?,
        afterCamera: CanvasCameraState?,
        actionName: String
    ) {
        guard windowFramesDiffer(before, after) || cameraStatesDiffer(beforeCamera, afterCamera) else { return }
        actionUndoManager.registerUndo(withTarget: self) { target in
            target.applyWindowFrameWithUndo(
                targetFrame: before,
                inverseFrame: after,
                targetCamera: beforeCamera,
                inverseCamera: afterCamera,
                actionName: actionName
            )
        }
        actionUndoManager.setActionName(actionName)
    }

    private func applyWindowFrameWithUndo(
        targetFrame: CGRect,
        inverseFrame: CGRect,
        targetCamera: CanvasCameraState?,
        inverseCamera: CanvasCameraState?,
        actionName: String
    ) {
        guard let window = view.window else { return }
        actionUndoManager.registerUndo(withTarget: self) { target in
            target.applyWindowFrameWithUndo(
                targetFrame: inverseFrame,
                inverseFrame: targetFrame,
                targetCamera: inverseCamera,
                inverseCamera: targetCamera,
                actionName: actionName
            )
        }
        actionUndoManager.setActionName(actionName)

        suppressWindowResizeUndoRegistration = true
        suppressProgrammaticWindowResizeCameraAdjustment = true
        window.setFrame(targetFrame, display: true, animate: false)
        lastObservedWindowFrame = targetFrame
        if let targetCamera {
            applyCanvasCamera(targetCamera)
            scheduleCanvasCameraSaveDebounced()
        }
        suppressProgrammaticWindowResizeCameraAdjustment = false
        suppressWindowResizeUndoRegistration = false
    }

    private func windowFramesDiffer(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let epsilon: CGFloat = 0.5
        if abs(lhs.origin.x - rhs.origin.x) > epsilon { return true }
        if abs(lhs.origin.y - rhs.origin.y) > epsilon { return true }
        if abs(lhs.size.width - rhs.size.width) > epsilon { return true }
        if abs(lhs.size.height - rhs.size.height) > epsilon { return true }
        return false
    }

    private func cameraStatesDiffer(_ lhs: CanvasCameraState?, _ rhs: CanvasCameraState?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return false
        case let (.some(a), .some(b)):
            let epsilon: CGFloat = 0.0001
            if abs(a.magnification - b.magnification) > epsilon { return true }
            if abs(a.origin.x - b.origin.x) > epsilon { return true }
            if abs(a.origin.y - b.origin.y) > epsilon { return true }
            return false
        default:
            return true
        }
    }

    private func applyOrderWithUndo(targetOrder: [UUID], inverseOrder: [UUID], actionName: String) {
        workspaceStore.reorderWorkspaces(targetOrder)
        scheduleArrangementSync()
        actionUndoManager.registerUndo(withTarget: self) { target in
            target.applyOrderWithUndo(
                targetOrder: inverseOrder,
                inverseOrder: targetOrder,
                actionName: actionName
            )
        }
        actionUndoManager.setActionName(actionName)
    }

    private func scheduleStateSave() {
        guard !isRestoringState else { return }
        stateStore.scheduleSave(makeSnapshot())
    }

    private func makeSnapshot() -> PersistedWorkspaceState {
        let virtual = workspaceStore.workspaces.filter { $0.kind == .virtual }
        let focusedIndex: Int? = {
            guard let focusedID = workspaceStore.focusedWorkspaceID else { return nil }
            return virtual.firstIndex(where: { $0.id == focusedID })
        }()
        let focusedDisplaySerial: UInt32? = {
            guard let focusedID = workspaceStore.focusedWorkspaceID,
                  let focusedWorkspace = virtual.first(where: { $0.id == focusedID }) else {
                return nil
            }
            return displayManager.virtualDisplaySerial(for: focusedWorkspace.displayID)
        }()

        let entries = virtual.map { workspace in
            let canvasX = workspace.canvasOrigin.map { Double($0.x) }
            let canvasY = workspace.canvasOrigin.map { Double($0.y) }
            return PersistedWorkspaceState.WorkspaceEntry(
                title: workspace.title,
                pixelWidth: max(1, Int(workspace.displayPixelSize.width.rounded())),
                pixelHeight: max(1, Int(workspace.displayPixelSize.height.rounded())),
                tileWidth: workspace.tileSize.width,
                tileHeight: workspace.tileSize.height,
                displaySerial: displayManager.virtualDisplaySerial(for: workspace.displayID),
                canvasX: canvasX,
                canvasY: canvasY
            )
        }

        let cameraToPersist = currentCanvasCameraState() ?? lastCanvasCamera
        let currentWindowFrame = view.window?.frame ?? lastObservedWindowFrame
        let windowedRestoreFrame = seamlessModeEnabled
            ? seamlessRestoreWindowFrame
            : currentWindowFrame
        let windowedRestoreCamera = seamlessModeEnabled
            ? seamlessRestoreCamera
            : cameraToPersist

        return PersistedWorkspaceState(
            version: 1,
            nextVirtualIndex: nextVirtualIndex,
            focusedIndex: focusedIndex,
            focusedDisplaySerial: focusedDisplaySerial,
            dynamicLayoutColumns: nil,
            layoutModeRawValue: WorkspaceLayoutMode.canvas.rawValue,
            canvasMagnification: cameraToPersist.map { Double($0.magnification) },
            canvasOffsetX: cameraToPersist.map { Double($0.origin.x) },
            canvasOffsetY: cameraToPersist.map { Double($0.origin.y) },
            windowX: currentWindowFrame.map { Double($0.origin.x) },
            windowY: currentWindowFrame.map { Double($0.origin.y) },
            windowWidth: currentWindowFrame.map { Double($0.size.width) },
            windowHeight: currentWindowFrame.map { Double($0.size.height) },
            windowedRestoreX: windowedRestoreFrame.map { Double($0.origin.x) },
            windowedRestoreY: windowedRestoreFrame.map { Double($0.origin.y) },
            windowedRestoreWidth: windowedRestoreFrame.map { Double($0.size.width) },
            windowedRestoreHeight: windowedRestoreFrame.map { Double($0.size.height) },
            windowedRestoreCanvasMagnification: windowedRestoreCamera.map { Double($0.magnification) },
            windowedRestoreCanvasOffsetX: windowedRestoreCamera.map { Double($0.origin.x) },
            windowedRestoreCanvasOffsetY: windowedRestoreCamera.map { Double($0.origin.y) },
            canvasSavepoints: persistedCanvasSavepoints(),
            arrangePadding: Double(arrangePadding),
            autoArrangeModeRawValue: autoArrangeMode?.rawValue,
            sharpCorners: sharpCornersPreferenceEnabled ? true : nil,
            seamlessMode: seamlessModeEnabled ? true : nil,
            requireHoldingMoveShortcut: requireHoldingMoveShortcutEnabled ? true : nil,
            limitFPS: fpsLimitValue,
            unlockFPSIfInteracting: unlockFPSIfInteractingEnabled,
            unlockFPSIfLargerThanPercent: unlockFPSIfLargerThanPercentEnabled,
            unlockFPSLargerThanPercentThreshold: unlockFPSLargerThanPercentThreshold,
            workspaces: entries
        )
    }

    private struct BootstrapState {
        let workspaces: [Workspace]
        let focusedWorkspaceID: UUID?
        let nextVirtualIndex: Int
        let canvasCamera: CanvasCameraState?
        let canvasSavepoints: [Int: CanvasSavepoint]
        let windowFrame: CGRect?
        let seamlessRestoreWindowFrame: CGRect?
        let seamlessRestoreCamera: CanvasCameraState?
        let arrangePadding: CGFloat?
        let autoArrangeMode: ArrangeMode?
        let sharpCorners: Bool
        let seamlessMode: Bool
        let requireHoldingMoveShortcut: Bool
        let limitFPS: Double
        let unlockFPSIfInteracting: Bool
        let unlockFPSIfLargerThanPercent: Bool
        let unlockFPSLargerThanPercentThreshold: Double
    }

    private func buildBootstrapState() -> BootstrapState {
        guard let persisted = stateStore.load(),
              persisted.version >= 1,
              !persisted.workspaces.isEmpty else {
            return BootstrapState(
                workspaces: [],
                focusedWorkspaceID: nil,
                nextVirtualIndex: nextVirtualIndex,
                canvasCamera: nil,
                canvasSavepoints: [:],
                windowFrame: nil,
                seamlessRestoreWindowFrame: nil,
                seamlessRestoreCamera: nil,
                arrangePadding: nil,
                autoArrangeMode: nil,
                sharpCorners: false,
                seamlessMode: false,
                requireHoldingMoveShortcut: false,
                limitFPS: 60.0,
                unlockFPSIfInteracting: true,
                unlockFPSIfLargerThanPercent: false,
                unlockFPSLargerThanPercentThreshold: 70.0
            )
        }
        let profile = displayManager.mainDisplayProfile()

        var restored: [Workspace] = []
        var restoredSerialByWorkspaceID: [UUID: UInt32] = [:]
        restored.reserveCapacity(persisted.workspaces.count)

        for (index, entry) in persisted.workspaces.enumerated() {
            let title = entry.title.isEmpty ? "\(index + 1)" : entry.title
            guard let descriptor = displayManager.createVirtualDisplay(
                name: title,
                width: profile.width,
                height: profile.height,
                hidpi: profile.hiDPI,
                physicalSizeMM: profile.physicalSizeMM,
                serialNumber: entry.displaySerial
            ) else {
                continue
            }

            let tileSize = TileGeometry.defaultTileSize(pixelSize: descriptor.pixelSize)

            let restoredWorkspace = Workspace(
                id: UUID(),
                displayID: descriptor.displayID,
                title: descriptor.title,
                kind: .virtual,
                displayPixelSize: descriptor.pixelSize,
                tileSize: tileSize,
                canvasOrigin: restoredCanvasOrigin(from: entry)
            )
            restored.append(restoredWorkspace)
            if let serial = entry.displaySerial {
                restoredSerialByWorkspaceID[restoredWorkspace.id] = serial
            }
        }

        let focusedID: UUID?
        if let focusedSerial = persisted.focusedDisplaySerial,
           let matched = restored.first(where: { restoredSerialByWorkspaceID[$0.id] == focusedSerial }) {
            focusedID = matched.id
        } else if let idx = persisted.focusedIndex, idx >= 0, idx < restored.count {
            focusedID = restored[idx].id
        } else {
            focusedID = restored.first?.id
        }

        return BootstrapState(
            workspaces: restored,
            focusedWorkspaceID: focusedID,
            nextVirtualIndex: max(persisted.nextVirtualIndex, restored.count + 1),
            canvasCamera: restoredCanvasCamera(from: persisted),
            canvasSavepoints: restoredCanvasSavepoints(
                from: persisted,
                serialToID: Dictionary(uniqueKeysWithValues: restoredSerialByWorkspaceID.map { ($0.value, $0.key) }),
                indexToID: restored.map(\.id)
            ),
            windowFrame: restoredWindowFrame(
                x: persisted.windowX,
                y: persisted.windowY,
                width: persisted.windowWidth,
                height: persisted.windowHeight
            ),
            seamlessRestoreWindowFrame: restoredWindowFrame(
                x: persisted.windowedRestoreX,
                y: persisted.windowedRestoreY,
                width: persisted.windowedRestoreWidth,
                height: persisted.windowedRestoreHeight
            ),
            seamlessRestoreCamera: restoredCamera(
                magnification: persisted.windowedRestoreCanvasMagnification,
                x: persisted.windowedRestoreCanvasOffsetX,
                y: persisted.windowedRestoreCanvasOffsetY
            ),
            arrangePadding: persisted.arrangePadding.map { CGFloat($0) },
            autoArrangeMode: persisted.autoArrangeModeRawValue.flatMap { ArrangeMode(rawValue: $0) },
            sharpCorners: persisted.sharpCorners ?? false,
            seamlessMode: persisted.seamlessMode ?? false,
            requireHoldingMoveShortcut: persisted.requireHoldingMoveShortcut ?? false,
            limitFPS: clampedFPSLimit(persisted.limitFPS ?? 60.0),
            unlockFPSIfInteracting: persisted.unlockFPSIfInteracting ?? true,
            unlockFPSIfLargerThanPercent: persisted.unlockFPSIfLargerThanPercent ?? false,
            unlockFPSLargerThanPercentThreshold: clampedFPSUnlockCoverageThreshold(
                persisted.unlockFPSLargerThanPercentThreshold ?? 70.0
            )
        )
    }

    private func restoredCanvasOrigin(from entry: PersistedWorkspaceState.WorkspaceEntry) -> CGPoint? {
        guard let x = entry.canvasX, let y = entry.canvasY else { return nil }
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func restoredCanvasCamera(from persisted: PersistedWorkspaceState) -> CanvasCameraState? {
        restoredCamera(
            magnification: persisted.canvasMagnification,
            x: persisted.canvasOffsetX,
            y: persisted.canvasOffsetY
        )
    }

    private func restoredCamera(
        magnification: Double?,
        x: Double?,
        y: Double?
    ) -> CanvasCameraState? {
        guard let magnification, let x, let y else {
            return nil
        }
        guard magnification.isFinite, x.isFinite, y.isFinite, magnification > 0 else {
            return nil
        }
        return CanvasCameraState(
            magnification: CGFloat(magnification),
            origin: CGPoint(x: x, y: y)
        )
    }

    private func restoredWindowFrame(
        x: Double?,
        y: Double?,
        width: Double?,
        height: Double?
    ) -> CGRect? {
        guard let x, let y, let width, let height,
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 1, height > 1 else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func menuFullscreenSelected() {
        openFullscreenForHoveredWorkspace()
    }

    func menuResetCanvasZoom() {
        guard currentLayoutMode == .canvas else { return }
        let viewportSize = gridView.bounds.size
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }
        let worldCenter = CGPoint(
            x: gridView.cameraOrigin.x + viewportSize.width / (2.0 * max(0.01, gridView.cameraMagnification)),
            y: gridView.cameraOrigin.y + viewportSize.height / (2.0 * max(0.01, gridView.cameraMagnification))
        )
        gridView.cameraMagnification = 1.0
        gridView.cameraOrigin = CGPoint(
            x: worldCenter.x - viewportSize.width / 2.0,
            y: worldCenter.y - viewportSize.height / 2.0
        )
        lastCanvasCamera = currentCanvasCameraState() ?? lastCanvasCamera
        scheduleDisplayStreamRefresh()
        scheduleStateSave()
    }

    func menuJumpToCanvasOrigin() {
        pushCameraHistory()
        let viewport = gridView.bounds.size
        guard viewport.width > 1, viewport.height > 1 else { return }
        let target = gridView.canvasViewportOriginForWorldOrigin(viewportSize: viewport)
        gridView.cameraOrigin = target
        lastCanvasCamera = currentCanvasCameraState() ?? lastCanvasCamera
        scheduleDisplayStreamRefresh()
        scheduleStateSave()
    }

    private func applyBootstrapState(_ bootstrap: BootstrapState) {
        isRestoringState = true
        if bootstrap.workspaces.isEmpty {
            workspaceStore.replaceWorkspaces(from: [])
        } else {
            workspaceStore.setWorkspaces(bootstrap.workspaces, focusedWorkspaceID: bootstrap.focusedWorkspaceID)
            nextVirtualIndex = bootstrap.nextVirtualIndex
        }
        currentLayoutMode = .canvas
        lastCanvasCamera = bootstrap.canvasCamera
        canvasSavepoints = bootstrap.canvasSavepoints
        seamlessRestoreWindowFrame = bootstrap.seamlessRestoreWindowFrame ?? bootstrap.windowFrame
        seamlessRestoreCamera = bootstrap.seamlessRestoreCamera ?? bootstrap.canvasCamera
        if let padding = bootstrap.arrangePadding { arrangePadding = padding }
        autoArrangeMode = bootstrap.autoArrangeMode
        sharpCornersPreferenceEnabled = bootstrap.sharpCorners
        seamlessModeEnabled = bootstrap.seamlessMode
        requireHoldingMoveShortcutEnabled = bootstrap.requireHoldingMoveShortcut
        fpsLimitValue = clampedFPSLimit(bootstrap.limitFPS)
        unlockFPSIfInteractingEnabled = bootstrap.unlockFPSIfInteracting
        unlockFPSIfLargerThanPercentEnabled = bootstrap.unlockFPSIfLargerThanPercent
        unlockFPSLargerThanPercentThreshold = clampedFPSUnlockCoverageThreshold(bootstrap.unlockFPSLargerThanPercentThreshold)
        if requireHoldingMoveShortcutEnabled {
            setWindowFollowToggleActive(false)
        }
        gridView.layoutMode = .canvas
        applyInteractionMode()
        workspaceStore.normalizeTileSizesForCurrentDisplays()
        hasUsedAdjacentJumpSinceBootstrap = false
        isRestoringState = false

        if hasScreenCaptureAccess {
            scheduleDisplayStreamRefresh(immediate: true, force: true)
        } else {
            setTileStatus("Screen Recording permission required for live display previews.")
        }
        if !bootstrap.workspaces.isEmpty {
            view.layoutSubtreeIfNeeded()
            layoutGridDocumentView()
            view.layoutSubtreeIfNeeded()
            applyDisplayArrangementImmediatelyIfNeeded()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let camera = self.lastCanvasCamera {
                self.applyCanvasCamera(camera)
            } else {
                self.centerCanvasViewport()
            }
            self.ensureVisibleWorkspaceAfterBootstrap()
            self.seedCameraHistoryIfNeeded()
            self.isRestoringState = false
            if !bootstrap.workspaces.isEmpty {
                self.scheduleStateSave()
            }
        }

        setTileStatus(nil)
        signalInitialBootstrapCompleteIfNeeded()
    }

    private func showToast(_ message: String, duration: TimeInterval = 2.5) {
        toastDismissWorkItem?.cancel()
        toastLabel.stringValue = message
        toastContainer.isHidden = false
        toastContainer.alphaValue = 1.0

        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                self?.toastContainer.animator().alphaValue = 0.0
            }, completionHandler: {
                self?.toastContainer.isHidden = true
                self?.toastContainer.alphaValue = 1.0
            })
        }
        toastDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func setTileStatus(_ message: String?) {
        if let message, !message.isEmpty {
            tileStatusLabel.stringValue = message
            tileStatusOverlay.isHidden = false
        } else {
            tileStatusOverlay.isHidden = true
            tileStatusLabel.stringValue = ""
        }
    }

    private func signalInitialBootstrapCompleteIfNeeded() {
        guard !didSignalInitialBootstrapComplete else { return }
        didSignalInitialBootstrapComplete = true
        onInitialBootstrapComplete?()
    }

}

private struct FocusLockOverlayGeometry {
    var outlineRect: CGRect = .zero
    var topCornerRadius: CGFloat = 0.0
}

private final class FocusLockBorderView: NSView {

    private let metalView = ChromaticAberrationMetalView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        metalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        metalView.overlayGeometry = resolvedOverlayGeometry()
        metalView.setNeedsDisplay(metalView.bounds)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        _ = point
        return nil
    }

    private func resolvedOverlayGeometry() -> FocusLockOverlayGeometry {
        FocusLockOverlayGeometry(
            outlineRect: bounds,
            topCornerRadius: resolvedTopCornerRadius(screenSafeInsets: window?.screen?.safeAreaInsets)
        )
    }

    private func resolvedTopCornerRadius(screenSafeInsets: NSEdgeInsets?) -> CGFloat {
        let edgeCandidates = [
            screenSafeInsets?.left ?? 0.0,
            screenSafeInsets?.right ?? 0.0,
        ].filter { $0 > 0.5 }
        if let smallest = edgeCandidates.min() {
            return min(max(smallest, 8.0), 36.0)
        }
        return defaultTopCornerRadius()
    }

    private func defaultTopCornerRadius() -> CGFloat {
        min(max(min(bounds.width, bounds.height) * 0.022, 12.0), 24.0)
    }
}

private final class ChromaticAberrationMetalView: MTKView, MTKViewDelegate {
    private struct Uniforms {
        var viewportSize: SIMD2<Float>
        var outlineRectMin: SIMD2<Float>
        var outlineRectMax: SIMD2<Float>
        var topCornerRadius: Float
        var bandWidth: Float
        var intensity: Float
        var feather: Float
    }

    private static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewportSize;
    float2 outlineRectMin;
    float2 outlineRectMax;
    float topCornerRadius;
    float bandWidth;
    float intensity;
    float feather;
};

struct VertexOut {
    float4 position [[position]];
    float2 pixel;
};

vertex VertexOut chromaticVertex(uint vid [[vertex_id]], constant Uniforms& uniforms [[buffer(0)]]) {
    constexpr float2 positions[6] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2(-1.0,  1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };
    constexpr float2 uvs[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(0.0, 1.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0)
    };

    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.pixel = uvs[vid] * uniforms.viewportSize;
    return out;
}

float topRoundedRectSDF(float2 pixel, float2 rectMin, float2 rectMax, float topRadius) {
    float2 rectSize = rectMax - rectMin;
    if (rectSize.x <= 0.5 || rectSize.y <= 0.5) {
        return 1e6;
    }

    topRadius = min(topRadius, min(rectSize.x * 0.5, rectSize.y));
    float2 center = (rectMin + rectMax) * 0.5;
    float2 halfSize = rectSize * 0.5;
    float2 local = pixel - center;

    // Corner radii by quadrant: top-right, bottom-right, top-left, bottom-left.
    float4 radii = float4(topRadius, 0.0, topRadius, 0.0);
    radii.xy = (local.x > 0.0) ? radii.xy : radii.zw;
    float radius = (local.y > 0.0) ? radii.x : radii.y;

    float2 q = abs(local) - halfSize + float2(radius);
    return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - radius;
}

float edgeBand(float d, float width, float feather) {
    float inner = max(width - feather, 0.5);
    float x = abs(d);
    return (1.0 - smoothstep(inner, max(width, inner + 0.5), x));
}

float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

fragment float4 chromaticFragment(VertexOut in [[stage_in]], constant Uniforms& uniforms [[buffer(0)]]) {
    float2 outlineMin = uniforms.outlineRectMin;
    float2 outlineMax = uniforms.outlineRectMax;
    float radius = min(uniforms.topCornerRadius, (outlineMax.x - outlineMin.x) * 0.5);

    float base = topRoundedRectSDF(in.pixel, outlineMin, outlineMax, radius);
    float ring = edgeBand(base, uniforms.bandWidth, uniforms.feather);

    float2 centered = in.pixel - uniforms.viewportSize * 0.5;
    float angle = atan2(centered.y, centered.x);
    float hue = fract(angle / (2.0 * 3.14159265) + 0.5 + base * 0.0025);
    float3 rainbow = hsv2rgb(float3(hue, 0.80, 1.0));

    float3 color = rainbow * ring;
    color *= uniforms.intensity;

    float alpha = saturate(ring) * uniforms.intensity;
    if (alpha <= 0.001) {
        discard_fragment();
    }
    return float4(color, alpha);
}
"""

    var overlayGeometry = FocusLockOverlayGeometry() {
        didSet {
            if geometryChanged(from: oldValue, to: overlayGeometry) {
                setNeedsDisplay(bounds)
            }
        }
    }

    private var pipelineState: MTLRenderPipelineState?
    private var commandQueue: MTLCommandQueue?

    override var isOpaque: Bool {
        false
    }

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        let resolvedDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: resolvedDevice)
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        device = MTLCreateSystemDefaultDevice()
        commonInit()
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorPixelFormat = .bgra8Unorm
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        delegate = self
        guard let device else { return }
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let vertexFunction = library.makeFunction(name: "chromaticVertex")
            let fragmentFunction = library.makeFunction(name: "chromaticFragment")
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            commandQueue = device.makeCommandQueue()
        } catch {
            pipelineState = nil
            commandQueue = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
        setNeedsDisplay(bounds)
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
        setNeedsDisplay(bounds)
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        drawableSize = CGSize(width: max(1.0, bounds.width * scale), height: max(1.0, bounds.height * scale))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        _ = view
        _ = size
    }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let renderPassDescriptor = currentRenderPassDescriptor,
              let pipelineState,
              let commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        var uniforms = makeUniforms()
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeUniforms() -> Uniforms {
        let size = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        let outlineRect = overlayGeometry.outlineRect.isEmpty ? bounds : overlayGeometry.outlineRect
        return Uniforms(
            viewportSize: size,
            outlineRectMin: SIMD2<Float>(Float(outlineRect.minX), Float(outlineRect.minY)),
            outlineRectMax: SIMD2<Float>(Float(outlineRect.maxX), Float(outlineRect.maxY)),
            topCornerRadius: Float(overlayGeometry.topCornerRadius),
            bandWidth: 4.0,
            intensity: 0.95,
            feather: 2.5
        )
    }

    private func geometryChanged(from oldValue: FocusLockOverlayGeometry, to newValue: FocusLockOverlayGeometry) -> Bool {
        rectChanged(from: oldValue.outlineRect, to: newValue.outlineRect)
            || abs(oldValue.topCornerRadius - newValue.topCornerRadius) > 0.5
    }

    private func rectChanged(from oldValue: CGRect, to newValue: CGRect) -> Bool {
        abs(oldValue.minX - newValue.minX) > 0.5
            || abs(oldValue.minY - newValue.minY) > 0.5
            || abs(oldValue.maxX - newValue.maxX) > 0.5
            || abs(oldValue.maxY - newValue.maxY) > 0.5
    }
}
