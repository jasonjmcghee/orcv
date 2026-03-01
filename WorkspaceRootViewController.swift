import AppKit
import CoreGraphics
import Foundation
import IOSurface

final class WorkspaceRootViewController: NSViewController {
    private struct CanvasCameraState {
        let magnification: CGFloat
        let origin: CGPoint
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
    private let macroEngine = InputMacroEngine()
    private let actionUndoManager = UndoManager()

    private var nextVirtualIndex: Int = 1
    private var localSwipeMonitor: Any?
    private var globalSwipeMonitor: Any?
    private var localCanvasScrollMonitor: Any?
    private var globalCanvasScrollMonitor: Any?
    private var localMagnifyMonitor: Any?
    private var globalMagnifyMonitor: Any?
    private var canvasCameraSaveDebounceWorkItem: DispatchWorkItem?
    private var windowLevelPollingTimer: Timer?
    private var spaceFollowWindowTimer: Timer?
    private var lastSpaceFollowMouseScreenPoint: CGPoint?
    private var isGridWindowFloating = false
    private var lastTeleportTime: TimeInterval = 0
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
    private var canvasSavepoints: [Int: CanvasCameraState] = [:]
    private var isRestoringState = false
    private var isTileResizeInProgress = false
    private var pendingStateSaveAfterResize = false
    private var resizeUndoBaseline: [UUID: CGSize]?
    private let lifecycleQueue = DispatchQueue(label: "today.jason.orcv.lifecycle", qos: .userInitiated)
    private var didSignalInitialBootstrapComplete = false
    private let minCanvasMagnification: CGFloat = 0.05
    private let maxCanvasMagnification: CGFloat = 8.0

    var onMacroStateDidChange: (() -> Void)?
    var onInitialBootstrapComplete: (() -> Void)?

    init(
        displayManager: VirtualDisplayManager,
        workspaceStore: WorkspaceStore,
        pointerRouter: PointerRouter,
        shortcutManager: ShortcutManager,
        stateStore: WorkspaceStateStore,
        hasScreenCaptureAccess: Bool
    ) {
        self.displayManager = displayManager
        self.workspaceStore = workspaceStore
        self.pointerRouter = pointerRouter
        self.shortcutManager = shortcutManager
        self.stateStore = stateStore
        self.hasScreenCaptureAccess = hasScreenCaptureAccess
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
        canvasCameraSaveDebounceWorkItem?.cancel()
        immersiveTeleportWorkItem?.cancel()
        windowLevelPollingTimer?.invalidate()
        spaceFollowWindowTimer?.invalidate()
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
        installWindowLevelMonitorIfNeeded()
        installSpaceFollowWindowMonitorIfNeeded()
        refreshGridWindowLevelForPointerMapping()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        teardownWindowLevelMonitor()
        teardownSpaceFollowWindowMonitor()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutGridDocumentView()
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

        tileStatusOverlay.addSubview(tileStatusLabel)

        view.addSubview(canvasBackdropView)
        view.addSubview(gridView)
        view.addSubview(tileStatusOverlay)

        NSLayoutConstraint.activate([
            canvasBackdropView.topAnchor.constraint(equalTo: view.topAnchor),
            canvasBackdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasBackdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasBackdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            gridView.topAnchor.constraint(equalTo: view.topAnchor),
            gridView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gridView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            tileStatusOverlay.topAnchor.constraint(equalTo: gridView.topAnchor),
            tileStatusOverlay.leadingAnchor.constraint(equalTo: gridView.leadingAnchor),
            tileStatusOverlay.trailingAnchor.constraint(equalTo: gridView.trailingAnchor),
            tileStatusOverlay.bottomAnchor.constraint(equalTo: gridView.bottomAnchor),

            tileStatusLabel.centerXAnchor.constraint(equalTo: tileStatusOverlay.centerXAnchor),
            tileStatusLabel.centerYAnchor.constraint(equalTo: tileStatusOverlay.centerYAnchor),
        ])

        applyInteractionMode()
    }

    private func wireActions() {
        workspaceStore.onDidChange = { [weak self] in
            guard let self else { return }
            self.renderStore()
            if self.isTileResizeInProgress {
                self.pendingStateSaveAfterResize = true
            } else {
                self.scheduleStateSave()
            }
        }

        shortcutManager.onDidChange = { [weak self] in
            DispatchQueue.main.async {
                self?.renderStore()
            }
        }

        gridView.onFocusRequest = { [weak self] workspaceID, pointInTile, frameInGrid, modifiers in
            guard let self else { return }
            _ = pointInTile
            _ = frameInGrid
            if modifiers.contains(.command) || modifiers.contains(.shift) {
                self.workspaceStore.toggleSelection(workspaceID: workspaceID)
            } else {
                self.workspaceStore.selectOnly(workspaceID: workspaceID)
            }
        }

        gridView.onBackgroundClick = { [weak self] in
            self?.workspaceStore.clearSelection()
        }
        gridView.onBackgroundWindowDragRequest = { [weak self] event in
            guard let self, let window = self.view.window else { return }
            if !self.isOrcvWindowFocused() {
                NSApp.activate(ignoringOtherApps: true)
            }
            window.performDrag(with: event)
        }

        gridView.onResizeRequest = { [weak self] workspaceID, newSize in
            guard let self else { return }
            self.workspaceStore.resizeAllWorkspaces(from: workspaceID, tileSize: newSize)
        }

        gridView.onResizeBegin = { [weak self] _ in
            self?.isTileResizeInProgress = true
            self?.arrangementDebounceWorkItem?.cancel()
            self?.gridView.suppressPreviewRebinds = true
            self?.resizeUndoBaseline = self?.tileSizesSnapshot()
        }

        gridView.onResizeCommit = { [weak self] _ in
            guard let self else { return }
            self.isTileResizeInProgress = false
            self.gridView.suppressPreviewRebinds = false
            self.gridView.refreshPreviews()
            if let before = self.resizeUndoBaseline {
                self.resizeUndoBaseline = nil
                let after = self.tileSizesSnapshot()
                self.registerTileSizeUndo(from: before, to: after, actionName: "Resize Tiles")
            }
            if self.pendingStateSaveAfterResize {
                self.pendingStateSaveAfterResize = false
                self.scheduleStateSave()
            }
            self.scheduleArrangementSync()
            self.refreshGridWindowLevelForPointerMapping()
        }

        gridView.onReorderCommit = { [weak self] orderedIDs in
            guard let self else { return }
            let previousOrder = self.workspaceStore.workspaces.map(\.id)
            self.workspaceStore.reorderWorkspaces(orderedIDs)
            let appliedOrder = self.workspaceStore.workspaces.map(\.id)
            self.scheduleArrangementSync()
            self.registerOrderUndo(from: previousOrder, to: appliedOrder, actionName: "Reorder Displays")
        }

        gridView.onCanvasMoveCommit = { [weak self] workspaceID, origin in
            self?.workspaceStore.updateCanvasOrigin(workspaceID: workspaceID, origin: origin)
            self?.scheduleArrangementSync()
        }

        gridView.layoutMode = .canvas

        gridView.referenceProvider = { [weak self] workspace in
            self?.reference(for: workspace) ?? SurfaceReference(displayID: workspace.displayID)
        }
        gridView.referenceSurfaceProvider = { [weak self] reference in
            self?.surface(for: reference)
        }

        streamManager.onFrame = nil

        streamManager.onDisplayFrame = { [weak self] displayID, surface in
            if self?.isTileResizeInProgress != true {
                self?.gridView.refreshPreviews(for: displayID)
            }
            self?.previewWindowController.consumeFrame(displayID: displayID, surface: surface)
            self?.maybeRefreshDisplayPixelSizeFromSystem(displayID: displayID, surface: surface)
        }

        streamManager.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.setTileStatus(message)
            }
        }

        macroEngine.onStateChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.renderStore()
            }
        }

        installSwipeMonitorsIfNeeded()
        installMagnificationMonitorIfNeeded()
        installCanvasScrollMonitorsIfNeeded()
        updateMacroControls()
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
        gridView.workspaces = workspaceStore.workspaces
        gridView.focusedWorkspaceID = workspaceStore.focusedWorkspaceID
        gridView.selectedWorkspaceIDs = workspaceStore.selectedWorkspaceIDs
        layoutGridDocumentView()
        guard !isTileResizeInProgress else { return }

        let validDisplayIDs = Set(workspaceStore.workspaces.map(\.displayID))
        previewWindowController.closeIfDisplayMissing(validDisplayIDs: validDisplayIDs)
        updateMacroControls()
        refreshGridWindowLevelForPointerMapping()
    }

    @objc
    private func handleStartRecording() {
        let virtualIDs = Set(workspaceStore.workspaces.filter { $0.kind == .virtual }.map(\.displayID))
        if !macroEngine.startRecording(virtualDisplayIDs: virtualIDs) {
            NSSound.beep()
        }
    }

    @objc
    private func handleStopRecording() {
        macroEngine.stopRecording()
    }

    @objc
    private func handleReplayRecording() {
        let selectedTargets = workspaceStore.selectedWorkspaces.filter { $0.kind == .virtual }
        let targets: [Workspace]
        if !selectedTargets.isEmpty {
            targets = selectedTargets
        } else if let focused = workspaceStore.focusedWorkspace, focused.kind == .virtual {
            targets = [focused]
        } else {
            targets = []
        }

        guard !targets.isEmpty else {
            NSSound.beep()
            return
        }

        macroEngine.replaySequential(on: targets.map(\.displayID))
    }

    private func updateMacroControls() {
        onMacroStateDidChange?()
    }

    func macroState() -> (isRecording: Bool, isReplaying: Bool, hasRecording: Bool) {
        (
            isRecording: macroEngine.isRecording,
            isReplaying: macroEngine.isReplaying,
            hasRecording: macroEngine.recordedEventCount > 0
        )
    }

    func menuToggleRecording() {
        if macroEngine.isRecording {
            handleStopRecording()
        } else if !macroEngine.isReplaying {
            handleStartRecording()
        }
    }

    func menuReplayRecording() {
        guard !macroEngine.isRecording, !macroEngine.isReplaying else { return }
        handleReplayRecording()
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
        nextVirtualIndex += 1
        registerUndoForCreate(workspaceID: created.id, actionName: "New Display")
    }

    @objc
    private func handleRemoveFocused() {
        guard let focused = workspaceStore.focusedWorkspace, focused.kind == .virtual else {
            NSSound.beep()
            return
        }
        guard let removed = removeVirtualWorkspace(workspaceID: focused.id) else {
            NSSound.beep()
            return
        }
        registerUndoForDelete(removed: removed.workspace, index: removed.index, actionName: "Remove Display")
    }

    private func currentDisplayDescriptors() -> [DisplayDescriptor] {
        workspaceStore.workspaces.map {
            DisplayDescriptor(
                displayID: $0.displayID,
                title: $0.title,
                pixelSize: $0.displayPixelSize,
                kind: $0.kind
            )
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
        handleRemoveFocused()
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
        streamManager.configureStreams(for: currentDisplayDescriptors())
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
        streamManager.configureStreams(for: currentDisplayDescriptors())
        scheduleArrangementSync()
        return removed
    }

    private func registerUndoForCreate(workspaceID: UUID, actionName: String) {
        actionUndoManager.registerUndo(withTarget: self) { target in
            guard let removed = target.removeVirtualWorkspace(workspaceID: workspaceID) else { return }
            target.registerUndoForDelete(removed: removed.workspace, index: removed.index, actionName: actionName)
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
        }
        actionUndoManager.setActionName(actionName)
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

    @discardableResult
    private func handleCanvasMagnify(_ event: NSEvent, requireUnfocusedWindow: Bool) -> Bool {
        guard currentLayoutMode == .canvas else { return false }
        guard let window = view.window, window.isVisible else { return false }
        if requireUnfocusedWindow, isOrcvWindowFocused() {
            return false
        }

        let delta = event.magnification
        guard delta.isFinite, abs(delta) > 0.0001 else { return false }

        let mouseInScreen = NSEvent.mouseLocation
        let mouseInWindow = window.convertPoint(fromScreen: mouseInScreen)
        let mouseInGrid = gridView.convert(mouseInWindow, from: nil)
        guard gridView.bounds.contains(mouseInGrid) else { return false }
        return applyCanvasZoom(magnificationDelta: delta, anchorViewPoint: mouseInGrid)
    }

    @discardableResult
    private func handleCanvasScrollEvent(_ event: NSEvent, requireUnfocusedWindow: Bool) -> Bool {
        guard currentLayoutMode == .canvas else { return false }
        guard let window = view.window, window.isVisible else { return false }
        if requireUnfocusedWindow, isOrcvWindowFocused() {
            return false
        }

        let mouseInScreen = NSEvent.mouseLocation
        let mouseInWindow = window.convertPoint(fromScreen: mouseInScreen)
        let mouseInGrid = gridView.convert(mouseInWindow, from: nil)
        guard gridView.bounds.contains(mouseInGrid) else { return false }

        let rawDeltaX = event.scrollingDeltaX
        let rawDeltaY = event.scrollingDeltaY
        guard rawDeltaX.isFinite, rawDeltaY.isFinite else { return false }

        let normalizedX = event.hasPreciseScrollingDeltas ? rawDeltaX : rawDeltaX * 10.0
        let normalizedY = event.hasPreciseScrollingDeltas ? rawDeltaY : rawDeltaY * 10.0

        if isZoomModifierActive(for: event) {
            let dominant = abs(normalizedY) >= abs(normalizedX) ? normalizedY : normalizedX
            guard abs(dominant) > 0.001 else { return false }
            let gain: CGFloat = event.hasPreciseScrollingDeltas ? 0.006 : 0.012
            let magnificationDelta = max(-0.12, min(0.12, dominant * gain))
            return applyCanvasZoom(magnificationDelta: magnificationDelta, anchorViewPoint: mouseInGrid)
        }

        return applyCanvasPan(deltaX: normalizedX, deltaY: normalizedY)
    }

    private func isZoomModifierActive(for event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            return true
        }
        return CGEventSource.keyState(.combinedSessionState, key: 55) ||
            CGEventSource.keyState(.combinedSessionState, key: 54)
    }

    @discardableResult
    private func applyCanvasZoom(magnificationDelta: CGFloat, anchorViewPoint: CGPoint) -> Bool {
        guard currentLayoutMode == .canvas else { return false }
        guard magnificationDelta.isFinite, abs(magnificationDelta) > 0.0001 else { return false }

        let currentMag = gridView.cameraMagnification
        let scaleFactor = max(0.05, 1.0 + magnificationDelta)
        let targetMag = currentMag * scaleFactor
        let clampedMag = max(minCanvasMagnification, min(maxCanvasMagnification, targetMag))
        guard abs(clampedMag - currentMag) > 0.0001 else { return false }

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
        return true
    }

    @discardableResult
    private func applyCanvasPan(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        guard currentLayoutMode == .canvas else { return false }
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
        return true
    }

    private func installWindowLevelMonitorIfNeeded() {
        guard windowLevelPollingTimer == nil else { return }
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.refreshGridWindowLevelForPointerMapping()
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
    }

    private func updateSpaceFollowWindowIfNeeded() {
        guard let window = view.window, window.isVisible else {
            lastSpaceFollowMouseScreenPoint = nil
            return
        }
        guard !previewWindowController.isPresenting else {
            lastSpaceFollowMouseScreenPoint = nil
            return
        }

        let spaceDown = CGEventSource.keyState(.combinedSessionState, key: 49)
        let commandDown = CGEventSource.keyState(.combinedSessionState, key: 55) ||
            CGEventSource.keyState(.combinedSessionState, key: 54)
        let optionDown = CGEventSource.keyState(.combinedSessionState, key: 58) ||
            CGEventSource.keyState(.combinedSessionState, key: 61)
        let controlDown = CGEventSource.keyState(.combinedSessionState, key: 59) ||
            CGEventSource.keyState(.combinedSessionState, key: 62)
        let plainSpaceDown = spaceDown && !commandDown && !optionDown && !controlDown
        let mouseInScreen = NSEvent.mouseLocation
        let hoveringWindow = window.frame.contains(mouseInScreen)
        let canFollow = plainSpaceDown && (hoveringWindow || isOrcvWindowFocused())

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
        applyTileLabelMode(modifiers: mods)
        if event.type == .keyDown {
            if let slot = digitSlotForNavigationEvent(event) {
                if shortcutMods == [.option], (1...9).contains(slot) {
                    guard isOrcvWindowFocused() else { return false }
                    _ = jumpToDisplaySlot(slot)
                    return true
                }
                if shortcutMods == [.command] {
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

            if event.keyCode == 49, shortcutMods.isEmpty {
                // Keep plain space available for "follow window" mode without system beep.
                return true
            }
        }

        guard let action = shortcutManager.action(for: event) else { return false }
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
            toggleTeleport()
            return true
        case .newDisplay:
            handleNewDisplay()
            return true
        case .removeDisplay:
            handleRemoveFocused()
            return true
        case .focusNext:
            workspaceStore.focusNextWorkspace()
            return true
        case .focusPrevious:
            workspaceStore.focusPreviousWorkspace()
            return true
        case .fullscreenSelected:
            openFullscreenForFocusedWorkspace()
            return true
        case .jumpNextDisplay:
            _ = jumpToAdjacentDisplay(step: 1)
            return true
        }
    }

    private func actionRequiresFocusedWindow(_ action: ShortcutAction) -> Bool {
        switch action {
        case .toggleTeleport:
            return false
        case .newDisplay, .removeDisplay, .focusNext, .focusPrevious, .fullscreenSelected, .jumpNextDisplay:
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
        if workspaceUnderCurrentMouseDisplay() != nil {
            teleportBackFromActiveWorkspace()
        } else {
            teleportIntoHoveredWorkspace()
        }
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
        let maxDisplays: UInt32 = 16
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var count: UInt32 = 0
        let result = CGGetDisplaysWithPoint(point, maxDisplays, &ids, &count)
        guard result == .success, count > 0 else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private func scheduleArrangementSync() {
        guard !isTileResizeInProgress else { return }
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

    private func openFullscreenForFocusedWorkspace() {
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

        guard let focused = workspaceStore.focusedWorkspace else {
            NSSound.beep()
            return
        }

        previewWindowController.presentImmersive(for: focused, on: view.window?.screen)
        refreshGridWindowLevelForPointerMapping()
        pointerRouter.teleportToDisplay(displayID: focused.displayID)
        let delayedTeleport = DispatchWorkItem { [weak self] in
            self?.pointerRouter.teleportToDisplay(displayID: focused.displayID)
        }
        immersiveTeleportWorkItem = delayedTeleport
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: delayedTeleport)
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

        streamManager.configureStreams(for: currentDisplayDescriptors())
        if !isTileResizeInProgress {
            scheduleArrangementSync()
        }
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
        canvasBackdropView.isHidden = false
        if gridView.cameraMagnification < minCanvasMagnification || gridView.cameraMagnification > maxCanvasMagnification {
            gridView.cameraMagnification = 1.0
        }
    }

    private func centerCanvasViewport() {
        guard currentLayoutMode == .canvas else { return }
        let viewportSize = gridView.bounds.size
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }
        let targetOrigin = gridView.canvasInitialViewportOrigin(for: viewportSize)
        gridView.cameraOrigin = targetOrigin
        if let camera = currentCanvasCameraState() { lastCanvasCamera = camera }
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
    }

    private func jumpToDisplaySlot(_ slot: Int) -> Bool {
        guard (1...9).contains(slot) else { return false }
        let workspaces = workspaceStore.workspaces
        let index = slot - 1
        guard index >= 0, index < workspaces.count else { return false }
        let target = workspaces[index]
        workspaceStore.selectOnly(workspaceID: target.id)
        return jumpCameraToWorkspace(workspaceID: target.id, fitWidth: true)
    }

    private func jumpToAdjacentDisplay(step: Int) -> Bool {
        let workspaces = workspaceStore.workspaces
        guard !workspaces.isEmpty else { return false }
        guard step != 0 else { return false }

        let currentIndex = workspaceStore.focusedWorkspaceID
            .flatMap { focusedID in workspaces.firstIndex(where: { $0.id == focusedID }) } ?? 0
        let count = workspaces.count
        let wrappedIndex = ((currentIndex + step) % count + count) % count
        let target = workspaces[wrappedIndex]
        workspaceStore.selectOnly(workspaceID: target.id)
        return jumpCameraToWorkspace(workspaceID: target.id, fitWidth: true)
    }

    private func jumpCameraToWorkspace(workspaceID: UUID, fitWidth: Bool) -> Bool {
        guard currentLayoutMode == .canvas else { return false }
        layoutGridDocumentView()
        view.layoutSubtreeIfNeeded()

        guard let worldFrame = gridView.frameForWorkspaceInWorld(workspaceID) else { return false }
        let viewport = gridView.bounds.size
        guard viewport.width > 1, viewport.height > 1 else { return false }

        var magnification = gridView.cameraMagnification
        if fitWidth {
            let desiredWidth = max(1.0, viewport.width * 0.90)
            magnification = desiredWidth / max(1.0, worldFrame.width)
            magnification = max(minCanvasMagnification, min(maxCanvasMagnification, magnification))
        }
        let safeMag = max(minCanvasMagnification, min(maxCanvasMagnification, magnification))
        let newOrigin = CGPoint(
            x: worldFrame.midX - viewport.width / (2.0 * safeMag),
            y: worldFrame.midY - viewport.height / (2.0 * safeMag)
        )

        gridView.cameraMagnification = safeMag
        gridView.cameraOrigin = newOrigin
        lastCanvasCamera = currentCanvasCameraState() ?? lastCanvasCamera
        scheduleCanvasCameraSaveDebounced()
        return true
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
        _ = jumpCameraToWorkspace(workspaceID: targetID, fitWidth: true)
    }

    private func saveCanvasSavepoint(slot: Int) -> Bool {
        guard (0...9).contains(slot) else { return false }
        guard let camera = (currentLayoutMode == .canvas ? currentCanvasCameraState() : nil)
            ?? lastCanvasCamera
            ?? defaultCanvasCameraState() else { return false }
        canvasSavepoints[slot] = camera
        lastCanvasCamera = camera
        scheduleStateSave()
        return true
    }

    private func recallCanvasSavepoint(slot: Int) -> Bool {
        guard (0...9).contains(slot), let camera = canvasSavepoints[slot] else { return false }
        lastCanvasCamera = camera
        applyCanvasCamera(camera)
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
        var encoded: [String: PersistedWorkspaceState.CameraBookmark] = [:]
        for (slot, camera) in canvasSavepoints where (0...9).contains(slot) {
            encoded[String(slot)] = PersistedWorkspaceState.CameraBookmark(
                magnification: Double(camera.magnification),
                offsetX: Double(camera.origin.x),
                offsetY: Double(camera.origin.y)
            )
        }
        return encoded.isEmpty ? nil : encoded
    }

    private func restoredCanvasSavepoints(from persisted: PersistedWorkspaceState) -> [Int: CanvasCameraState] {
        guard let raw = persisted.canvasSavepoints, !raw.isEmpty else { return [:] }
        var decoded: [Int: CanvasCameraState] = [:]
        for (slotKey, bookmark) in raw {
            guard let slot = Int(slotKey), (0...9).contains(slot) else { continue }
            let magnification = CGFloat(bookmark.magnification)
            let x = CGFloat(bookmark.offsetX)
            let y = CGFloat(bookmark.offsetY)
            guard magnification.isFinite, magnification > 0, x.isFinite, y.isFinite else { continue }
            decoded[slot] = CanvasCameraState(
                magnification: magnification,
                origin: CGPoint(x: x, y: y)
            )
        }
        return decoded
    }

    private func applyTileLabelMode(modifiers: NSEvent.ModifierFlags) {
        gridView.showsDisplayIDs = modifiers.contains(.option)
    }

    private func tileSizesSnapshot() -> [UUID: CGSize] {
        Dictionary(uniqueKeysWithValues: workspaceStore.workspaces.map { ($0.id, $0.tileSize) })
    }

    private func tileSizeSnapshotsEqual(_ lhs: [UUID: CGSize], _ rhs: [UUID: CGSize]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (id, l) in lhs {
            guard let r = rhs[id] else { return false }
            if abs(l.width - r.width) > 0.5 || abs(l.height - r.height) > 0.5 {
                return false
            }
        }
        return true
    }

    private func registerTileSizeUndo(from before: [UUID: CGSize], to after: [UUID: CGSize], actionName: String) {
        guard !tileSizeSnapshotsEqual(before, after) else { return }
        actionUndoManager.registerUndo(withTarget: self) { target in
            target.applyTileSizesWithUndo(
                targetSizes: before,
                inverseSizes: after,
                actionName: actionName
            )
        }
        actionUndoManager.setActionName(actionName)
    }

    private func applyTileSizesWithUndo(
        targetSizes: [UUID: CGSize],
        inverseSizes: [UUID: CGSize],
        actionName: String
    ) {
        workspaceStore.setTileSizes(targetSizes)
        scheduleArrangementSync()
        actionUndoManager.registerUndo(withTarget: self) { target in
            target.applyTileSizesWithUndo(
                targetSizes: inverseSizes,
                inverseSizes: targetSizes,
                actionName: actionName
            )
        }
        actionUndoManager.setActionName(actionName)
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
            canvasSavepoints: persistedCanvasSavepoints(),
            workspaces: entries
        )
    }

    private struct BootstrapState {
        let workspaces: [Workspace]
        let focusedWorkspaceID: UUID?
        let nextVirtualIndex: Int
        let canvasCamera: CanvasCameraState?
        let canvasSavepoints: [Int: CanvasCameraState]
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
                canvasSavepoints: [:]
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

            let tileSize = normalizedTileSize(
                CGSize(width: entry.tileWidth, height: entry.tileHeight),
                pixelSize: descriptor.pixelSize
            )

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
            canvasSavepoints: restoredCanvasSavepoints(from: persisted)
        )
    }

    private func normalizedTileSize(_ raw: CGSize, pixelSize: CGSize) -> CGSize {
        let ratio = max(0.1, pixelSize.width / max(1.0, pixelSize.height))
        let minHeight = max(140.0, 220.0 / ratio)
        let maxHeight = min(900.0, 1200.0 / ratio)

        var targetHeight = raw.height
        if !targetHeight.isFinite || targetHeight <= 0 {
            targetHeight = 360.0 / ratio
        }
        targetHeight = max(minHeight, min(maxHeight, targetHeight))
        return CGSize(width: targetHeight * ratio, height: targetHeight)
    }

    private func restoredCanvasOrigin(from entry: PersistedWorkspaceState.WorkspaceEntry) -> CGPoint? {
        guard let x = entry.canvasX, let y = entry.canvasY else { return nil }
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func restoredCanvasCamera(from persisted: PersistedWorkspaceState) -> CanvasCameraState? {
        guard let magnification = persisted.canvasMagnification,
              let x = persisted.canvasOffsetX,
              let y = persisted.canvasOffsetY else {
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

    func menuFullscreenSelected() {
        openFullscreenForFocusedWorkspace()
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
        scheduleStateSave()
    }

    func menuJumpToCanvasOrigin() {
        let viewport = gridView.bounds.size
        guard viewport.width > 1, viewport.height > 1 else { return }
        let target = gridView.canvasViewportOriginForWorldOrigin(viewportSize: viewport)
        gridView.cameraOrigin = target
        lastCanvasCamera = currentCanvasCameraState() ?? lastCanvasCamera
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
        gridView.layoutMode = .canvas
        applyInteractionMode()
        workspaceStore.normalizeTileSizesForCurrentDisplays()
        isRestoringState = false

        if hasScreenCaptureAccess {
            streamManager.configureStreams(for: currentDisplayDescriptors())
        } else {
            setTileStatus("Screen Recording permission required for live display previews.")
        }
        if !bootstrap.workspaces.isEmpty {
            view.layoutSubtreeIfNeeded()
            layoutGridDocumentView()
            view.layoutSubtreeIfNeeded()
            applyDisplayArrangementImmediatelyIfNeeded()
            scheduleStateSave()
        }
        DispatchQueue.main.async { [weak self] in
            if let camera = self?.lastCanvasCamera {
                self?.applyCanvasCamera(camera)
            } else {
                self?.centerCanvasViewport()
            }
            self?.ensureVisibleWorkspaceAfterBootstrap()
        }

        setTileStatus(nil)
        signalInitialBootstrapCompleteIfNeeded()
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
