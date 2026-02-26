import AppKit
import CoreGraphics
import Foundation

final class WorkspaceRootViewController: NSViewController {
    private let displayManager: VirtualDisplayManager
    private let workspaceStore: WorkspaceStore
    private let pointerRouter: PointerRouter
    private let shortcutManager: ShortcutManager
    private let stateStore: WorkspaceStateStore
    private let streamManager = DisplayStreamManager()
    private let hasScreenCaptureAccess: Bool
    private lazy var previewWindowController = WorkspacePreviewWindowController(surfaceProvider: { [weak self] displayID in
        self?.streamManager.latestSurface(for: displayID)
    })

    private let scrollView = NSScrollView(frame: .zero)
    private let gridView = WorkspaceGridView(frame: .zero)
    private let tileStatusOverlay = NSVisualEffectView(frame: .zero)
    private let tileStatusLabel = NSTextField(labelWithString: "")
    private let macroEngine = InputMacroEngine()
    private let actionUndoManager = UndoManager()

    private var nextVirtualIndex: Int = 1
    private var localSwipeMonitor: Any?
    private var globalSwipeMonitor: Any?
    private var windowLevelPollingTimer: Timer?
    private var isGridWindowFloating = false
    private var lastTeleportTime: TimeInterval = 0
    private var lastCommandTapTimestamp: TimeInterval = 0
    private var lastImmersiveToggleTime: TimeInterval = 0
    private var immersiveTeleportWorkItem: DispatchWorkItem?
    private var arrangementDebounceWorkItem: DispatchWorkItem?
    private var dynamicLayoutDebounceWorkItem: DispatchWorkItem?
    private var lastAppliedOrigins: [CGDirectDisplayID: CGPoint] = [:]
    private var activeDynamicLayoutColumns: Int?
    private var lastDynamicLayoutViewportWidth: CGFloat = 0
    private var isRestoringState = false
    private var resizeUndoBaseline: [UUID: CGSize]?
    private let lifecycleQueue = DispatchQueue(label: "com.pointworks.workspacegrid.lifecycle", qos: .userInitiated)

    var onMacroStateDidChange: (() -> Void)?

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
        immersiveTeleportWorkItem?.cancel()
        windowLevelPollingTimer?.invalidate()
        dynamicLayoutDebounceWorkItem?.cancel()
    }

    override var undoManager: UndoManager? {
        actionUndoManager
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        setupUI()
        wireActions()
        bootstrapDisplays()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installWindowLevelMonitorIfNeeded()
        refreshGridWindowLevelForPointerMapping()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        teardownWindowLevelMonitor()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutGridDocumentView()
        if view.window?.inLiveResize == true {
            scheduleDynamicLayoutRefreshDuringLiveResize()
        } else {
            dynamicLayoutDebounceWorkItem?.cancel()
            refreshDynamicPresetLayoutForViewportIfNeeded()
        }
    }

    private func setupUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        gridView.frame = NSRect(x: 0, y: 0, width: 1200, height: 720)
        scrollView.documentView = gridView

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

        view.addSubview(scrollView)
        view.addSubview(tileStatusOverlay)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            tileStatusOverlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            tileStatusOverlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            tileStatusOverlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            tileStatusOverlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            tileStatusLabel.centerXAnchor.constraint(equalTo: tileStatusOverlay.centerXAnchor),
            tileStatusLabel.centerYAnchor.constraint(equalTo: tileStatusOverlay.centerYAnchor),
        ])
    }

    private func wireActions() {
        workspaceStore.onDidChange = { [weak self] in
            self?.renderStore()
            self?.scheduleStateSave()
        }

        shortcutManager.onDidChange = { [weak self] in
            DispatchQueue.main.async {
                if self?.shortcutManager.tileSizingMode == .fixed {
                    self?.activeDynamicLayoutColumns = nil
                    self?.applyFixedReasonableTileSizing()
                } else {
                    self?.lastDynamicLayoutViewportWidth = 0
                }
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

        gridView.onResizeRequest = { [weak self] workspaceID, newSize in
            guard let self else { return }
            if self.shortcutManager.tileSizingMode == .fixed {
                self.applyFixedReasonableTileSizing()
            } else {
                self.activeDynamicLayoutColumns = nil
                self.workspaceStore.resizeAllWorkspaces(from: workspaceID, tileSize: newSize)
            }
            self.scheduleArrangementSync()
        }

        gridView.onResizeBegin = { [weak self] _ in
            self?.resizeUndoBaseline = self?.tileSizesSnapshot()
        }

        gridView.onResizeCommit = { [weak self] _ in
            guard let self else { return }
            guard let before = self.resizeUndoBaseline else { return }
            self.resizeUndoBaseline = nil
            let after = self.tileSizesSnapshot()
            self.registerTileSizeUndo(from: before, to: after, actionName: "Resize Tiles")
        }

        gridView.onReorderCommit = { [weak self] orderedIDs in
            guard let self else { return }
            let previousOrder = self.workspaceStore.workspaces.map(\.id)
            self.workspaceStore.reorderWorkspaces(orderedIDs)
            let appliedOrder = self.workspaceStore.workspaces.map(\.id)
            self.scheduleArrangementSync()
            self.registerOrderUndo(from: previousOrder, to: appliedOrder, actionName: "Reorder Displays")
        }

        gridView.surfaceProvider = { [weak self] displayID in
            self?.streamManager.latestSurface(for: displayID)
        }

        streamManager.onFrame = { [weak self] in
            self?.gridView.refreshPreviews()
        }

        streamManager.onDisplayFrame = { [weak self] displayID, surface in
            self?.previewWindowController.consumeFrame(displayID: displayID, surface: surface)
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
        let validDisplayIDs = Set(workspaceStore.workspaces.map(\.displayID))
        previewWindowController.closeIfDisplayMissing(validDisplayIDs: validDisplayIDs)
        layoutGridDocumentView()
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
        applyTileLabelMode(modifiers: mods)

        if maybeHandleDoubleCommandTap(event) {
            return true
        }

        if event.type != .keyDown {
            return false
        }

        if event.keyCode == 3, mods == [.control, .option] {
            openFullscreenForFocusedWorkspace()
            return true
        }

        guard let action = shortcutManager.action(for: event) else { return false }

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
            guard isWorkspaceGridWindowFocused() else { return false }
            handleNewDisplay()
            return true
        case .removeDisplay:
            guard isWorkspaceGridWindowFocused() else { return false }
            handleRemoveFocused()
            return true
        case .focusNext:
            workspaceStore.focusNextWorkspace()
            return true
        case .focusPrevious:
            workspaceStore.focusPreviousWorkspace()
            return true
        case .layoutFullWidth:
            applyLayout(columns: 1)
            return true
        case .layout2x2:
            applyLayout(columns: 2)
            return true
        case .fullscreenSelected:
            openFullscreenForFocusedWorkspace()
            return true
        }
    }

    private func isWorkspaceGridWindowFocused() -> Bool {
        guard NSApp.isActive, let window = view.window else { return false }
        return NSApp.keyWindow === window || NSApp.mainWindow === window
    }

    private func maybeHandleDoubleCommandTap(_ event: NSEvent) -> Bool {
        guard event.type == .flagsChanged else { return false }
        guard event.keyCode == 55 || event.keyCode == 54 else { return false } // left/right command

        let isDown = CGEventSource.keyState(.combinedSessionState, key: event.keyCode)
        guard isDown else { return false }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == [.command] else {
            lastCommandTapTimestamp = 0
            return false
        }

        let now = event.timestamp
        if lastCommandTapTimestamp > 0, now - lastCommandTapTimestamp <= 0.5 {
            lastCommandTapTimestamp = 0

            if previewWindowController.isPresenting {
                previewWindowController.closePreview()
                return true
            }

            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime - lastTeleportTime < 0.12 {
                return false
            }
            lastTeleportTime = uptime
            toggleTeleport()
            return true
        }

        lastCommandTapTimestamp = now
        return false
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

        let frameInWindow = gridView.convert(hit.frameInGrid, to: nil)
        pointerRouter.teleportInto(
            workspace: workspace,
            pointInTile: hit.pointInTile,
            tileFrameInWindow: frameInWindow
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
        arrangementDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.applyDisplayArrangementFromGrid()
        }
        arrangementDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: workItem)
    }

    private func applyDisplayArrangementFromGrid() {
        let virtualWorkspaces = workspaceStore.workspaces.filter { $0.kind == .virtual }
        guard !virtualWorkspaces.isEmpty else { return }

        struct Entry {
            let displayID: CGDirectDisplayID
            let tileFrameTopLeft: CGRect
            let displayBounds: CGRect
        }

        let contentHeight = gridView.bounds.height
        let entries: [Entry] = virtualWorkspaces.compactMap { workspace in
            guard let tileFrame = gridView.frameForWorkspaceInGrid(workspace.id) else { return nil }
            let displayBounds = CGDisplayBounds(workspace.displayID)
            guard tileFrame.width > 1, tileFrame.height > 1,
                  displayBounds.width > 1, displayBounds.height > 1 else {
                return nil
            }
            let topLeftFrame = CGRect(
                x: tileFrame.minX,
                y: contentHeight - tileFrame.maxY,
                width: tileFrame.width,
                height: tileFrame.height
            )
            return Entry(displayID: workspace.displayID, tileFrameTopLeft: topLeftFrame, displayBounds: displayBounds)
        }

        guard !entries.isEmpty else { return }

        var finalOrigins: [CGDirectDisplayID: CGPoint] = [:]
        let tileMinX = entries.map { $0.tileFrameTopLeft.minX }.min() ?? 0
        let tileMinY = entries.map { $0.tileFrameTopLeft.minY }.min() ?? 0
        let displayMinX = entries.map { $0.displayBounds.minX }.min() ?? 0
        let displayMinY = entries.map { $0.displayBounds.minY }.min() ?? 0

        let scaleCandidates = entries.flatMap { entry in
            [entry.displayBounds.width / entry.tileFrameTopLeft.width,
             entry.displayBounds.height / entry.tileFrameTopLeft.height]
        }
        let scale = median(of: scaleCandidates)
        guard scale > 0 else { return }

        for entry in entries {
            let mappedX = displayMinX + (entry.tileFrameTopLeft.minX - tileMinX) * scale
            let mappedY = displayMinY + (entry.tileFrameTopLeft.minY - tileMinY) * scale
            finalOrigins[entry.displayID] = CGPoint(x: mappedX.rounded(), y: mappedY.rounded())
        }

        guard !originsMatch(lhs: finalOrigins, rhs: lastAppliedOrigins) else { return }
        if displayManager.applyDisplayOrigins(finalOrigins) {
            lastAppliedOrigins = finalOrigins
        }
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
        let width = tileLayoutViewportWidth()
        let minHeight = max(1.0, scrollView.contentView.bounds.height)
        let neededHeight = max(minHeight, gridView.requiredContentHeight(forWidth: width))

        let newFrame = CGRect(x: 0, y: 0, width: width, height: neededHeight)
        if gridView.frame.size != newFrame.size {
            gridView.frame = newFrame
            gridView.needsLayout = true
            gridView.needsDisplay = true
        }
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

    private func applyLayout(columns: Int) {
        guard !workspaceStore.workspaces.isEmpty else { return }
        let before = tileSizesSnapshot()

        if shortcutManager.tileSizingMode == .dynamic {
            activeDynamicLayoutColumns = columns
            lastDynamicLayoutViewportWidth = 0
        } else {
            activeDynamicLayoutColumns = nil
        }

        let sizes: [UUID: CGSize] = Dictionary(uniqueKeysWithValues:
            workspaceStore.workspaces.map { workspace in
                (workspace.id, gridView.tileSize(for: workspace.displayPixelSize, columns: columns))
            }
        )
        workspaceStore.setTileSizes(sizes)
        scheduleArrangementSync()
        registerTileSizeUndo(from: before, to: tileSizesSnapshot(), actionName: "Layout")
    }

    private func applyFixedReasonableTileSizing() {
        guard !workspaceStore.workspaces.isEmpty else { return }
        let before = tileSizesSnapshot()
        activeDynamicLayoutColumns = nil
        let sizes: [UUID: CGSize] = Dictionary(uniqueKeysWithValues:
            workspaceStore.workspaces.map { workspace in
                (workspace.id, gridView.reasonableFixedTileSize(for: workspace.displayPixelSize))
            }
        )
        workspaceStore.setTileSizes(sizes)
        scheduleArrangementSync()
        registerTileSizeUndo(from: before, to: tileSizesSnapshot(), actionName: "Resize Tiles")
    }

    private func openFullscreenForFocusedWorkspace() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastImmersiveToggleTime < 0.16 {
            return
        }
        lastImmersiveToggleTime = now

        immersiveTeleportWorkItem?.cancel()
        immersiveTeleportWorkItem = nil

        if previewWindowController.isPresenting {
            previewWindowController.closePreview()
            refreshGridWindowLevelForPointerMapping()
            return
        }

        guard let focused = workspaceStore.focusedWorkspace else {
            NSSound.beep()
            return
        }

        previewWindowController.presentImmersive(for: focused)
        refreshGridWindowLevelForPointerMapping()
        pointerRouter.teleportToDisplay(displayID: focused.displayID)
        let delayedTeleport = DispatchWorkItem { [weak self] in
            self?.pointerRouter.teleportToDisplay(displayID: focused.displayID)
        }
        immersiveTeleportWorkItem = delayedTeleport
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: delayedTeleport)
    }

    private func refreshDynamicPresetLayoutForViewportIfNeeded() {
        guard shortcutManager.tileSizingMode == .dynamic,
              let columns = activeDynamicLayoutColumns,
              !workspaceStore.workspaces.isEmpty else {
            return
        }

        let viewportWidth = tileLayoutViewportWidth()
        guard abs(viewportWidth - lastDynamicLayoutViewportWidth) > 1.0 else { return }
        lastDynamicLayoutViewportWidth = viewportWidth

        let sizes: [UUID: CGSize] = Dictionary(uniqueKeysWithValues:
            workspaceStore.workspaces.map { workspace in
                (workspace.id, gridView.tileSize(for: workspace.displayPixelSize, columns: columns))
            }
        )
        workspaceStore.setTileSizes(sizes)
        scheduleArrangementSync()
    }

    private func tileLayoutViewportWidth() -> CGFloat {
        let baseWidth = max(1.0, scrollView.bounds.width)
        guard scrollView.scrollerStyle == .legacy, scrollView.hasVerticalScroller else {
            return baseWidth
        }

        // Keep layout width stable even if the legacy vertical scroller visibility toggles.
        let controlSize = scrollView.verticalScroller?.controlSize ?? .regular
        let scrollerWidth = NSScroller.scrollerWidth(for: controlSize, scrollerStyle: .legacy)
        return max(1.0, baseWidth - scrollerWidth)
    }

    private func scheduleDynamicLayoutRefreshDuringLiveResize() {
        dynamicLayoutDebounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshDynamicPresetLayoutForViewportIfNeeded()
        }
        dynamicLayoutDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
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

        let entries = virtual.map { workspace in
            PersistedWorkspaceState.WorkspaceEntry(
                title: workspace.title,
                pixelWidth: max(1, Int(workspace.displayPixelSize.width.rounded())),
                pixelHeight: max(1, Int(workspace.displayPixelSize.height.rounded())),
                tileWidth: workspace.tileSize.width,
                tileHeight: workspace.tileSize.height
            )
        }

        return PersistedWorkspaceState(
            version: 1,
            nextVirtualIndex: nextVirtualIndex,
            focusedIndex: focusedIndex,
            dynamicLayoutColumns: activeDynamicLayoutColumns,
            workspaces: entries
        )
    }

    private struct BootstrapState {
        let workspaces: [Workspace]
        let focusedWorkspaceID: UUID?
        let nextVirtualIndex: Int
        let dynamicLayoutColumns: Int?
    }

    private func buildBootstrapState() -> BootstrapState {
        guard let persisted = stateStore.load(),
              persisted.version == 1,
              !persisted.workspaces.isEmpty else {
            return BootstrapState(
                workspaces: [],
                focusedWorkspaceID: nil,
                nextVirtualIndex: nextVirtualIndex,
                dynamicLayoutColumns: nil
            )
        }
        let profile = displayManager.mainDisplayProfile()

        var restored: [Workspace] = []
        restored.reserveCapacity(persisted.workspaces.count)

        for (index, entry) in persisted.workspaces.enumerated() {
            let title = entry.title.isEmpty ? "\(index + 1)" : entry.title
            guard let descriptor = displayManager.createVirtualDisplay(
                name: title,
                width: profile.width,
                height: profile.height,
                hidpi: profile.hiDPI,
                physicalSizeMM: profile.physicalSizeMM
            ) else {
                continue
            }

            let tileSize = normalizedTileSize(
                CGSize(width: entry.tileWidth, height: entry.tileHeight),
                pixelSize: descriptor.pixelSize
            )

            restored.append(
                Workspace(
                    id: UUID(),
                    displayID: descriptor.displayID,
                    title: descriptor.title,
                    kind: .virtual,
                    displayPixelSize: descriptor.pixelSize,
                    tileSize: tileSize
                )
            )
        }

        let focusedID: UUID?
        if let idx = persisted.focusedIndex, idx >= 0, idx < restored.count {
            focusedID = restored[idx].id
        } else {
            focusedID = restored.first?.id
        }

        return BootstrapState(
            workspaces: restored,
            focusedWorkspaceID: focusedID,
            nextVirtualIndex: max(persisted.nextVirtualIndex, restored.count + 1),
            dynamicLayoutColumns: persisted.dynamicLayoutColumns
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

    func menuApplyLayoutFullWidth() {
        applyLayout(columns: 1)
    }

    func menuApplyLayout2x2() {
        applyLayout(columns: 2)
    }

    func menuFullscreenSelected() {
        openFullscreenForFocusedWorkspace()
    }

    func menuSetTileSizingMode(_ mode: TileSizingMode) {
        shortcutManager.updateTileSizingMode(mode)
        if mode == .fixed {
            applyFixedReasonableTileSizing()
        } else {
            lastDynamicLayoutViewportWidth = 0
            refreshDynamicPresetLayoutForViewportIfNeeded()
        }
    }

    private func applyBootstrapState(_ bootstrap: BootstrapState) {
        isRestoringState = true
        if bootstrap.workspaces.isEmpty {
            workspaceStore.replaceWorkspaces(from: [])
        } else {
            workspaceStore.setWorkspaces(bootstrap.workspaces, focusedWorkspaceID: bootstrap.focusedWorkspaceID)
            nextVirtualIndex = bootstrap.nextVirtualIndex
            activeDynamicLayoutColumns = bootstrap.dynamicLayoutColumns
        }
        isRestoringState = false

        if hasScreenCaptureAccess {
            streamManager.configureStreams(for: currentDisplayDescriptors())
        } else {
            setTileStatus("Screen Recording permission required for live display previews.")
        }
        if !bootstrap.workspaces.isEmpty {
            scheduleArrangementSync()
            scheduleStateSave()
        }

        setTileStatus(nil)
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

}
