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
    private let controlsStack = NSStackView(frame: .zero)
    private let addButton = NSButton(title: "New Display", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Display", target: nil, action: nil)
    private let tileStatusOverlay = NSVisualEffectView(frame: .zero)
    private let tileStatusLabel = NSTextField(labelWithString: "")
    private let macroEngine = InputMacroEngine()
    private var titlebarAccessoryController: NSTitlebarAccessoryViewController?

    private var nextVirtualIndex: Int = 1
    private var localSwipeMonitor: Any?
    private var globalSwipeMonitor: Any?
    private var lastTeleportTime: TimeInterval = 0
    private var lastCommandTapTimestamp: TimeInterval = 0
    private var arrangementDebounceWorkItem: DispatchWorkItem?
    private var dynamicLayoutDebounceWorkItem: DispatchWorkItem?
    private var lastAppliedOrigins: [CGDirectDisplayID: CGPoint] = [:]
    private var activeDynamicLayoutColumns: Int?
    private var lastDynamicLayoutViewportWidth: CGFloat = 0
    private var isRestoringState = false
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
        dynamicLayoutDebounceWorkItem?.cancel()
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        setupUI()
        wireActions()
        bootstrapDisplays()
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
        configureIconButton(addButton, symbolName: "plus", accessibilityLabel: "New Display")
        configureIconButton(removeButton, symbolName: "xmark", accessibilityLabel: "Remove Display")

        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.orientation = .horizontal
        controlsStack.alignment = .centerY
        controlsStack.spacing = 8
        controlsStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        controlsStack.addArrangedSubview(addButton)
        controlsStack.addArrangedSubview(removeButton)

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
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
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

    func attachTitlebarControls(to window: NSWindow) {
        if titlebarAccessoryController != nil {
            return
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 84, height: 40))
        container.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controlsStack)
        NSLayoutConstraint.activate([
            controlsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controlsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controlsStack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 8),
            container.heightAnchor.constraint(equalToConstant: 40),
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.fullScreenMinHeight = 40
        accessory.view = container
        window.addTitlebarAccessoryViewController(accessory)
        titlebarAccessoryController = accessory
    }

    private func configureIconButton(_ button: NSButton, symbolName: String, accessibilityLabel: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .texturedRounded
        button.controlSize = .regular
        button.title = ""
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        button.imagePosition = .imageOnly
        button.toolTip = accessibilityLabel
        button.contentTintColor = .labelColor
        button.setAccessibilityLabel(accessibilityLabel)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func wireActions() {
        addButton.target = self
        addButton.action = #selector(handleNewDisplay)

        removeButton.target = self
        removeButton.action = #selector(handleRemoveFocused)

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

        gridView.onReorderCommit = { [weak self] orderedIDs in
            self?.workspaceStore.reorderWorkspaces(orderedIDs)
            self?.scheduleArrangementSync()
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
        let name = "\(nextVirtualIndex)"
        nextVirtualIndex += 1
        let profile = displayManager.mainDisplayProfile()

        guard let descriptor = displayManager.createVirtualDisplay(
            name: name,
            width: profile.width,
            height: profile.height,
            hidpi: profile.hiDPI,
            physicalSizeMM: profile.physicalSizeMM
        ) else {
            NSSound.beep()
            return
        }

        workspaceStore.addWorkspace(from: descriptor)
        if let templateTileSize,
           let newWorkspaceID = workspaceStore.focusedWorkspaceID {
            workspaceStore.resizeWorkspace(workspaceID: newWorkspaceID, tileSize: templateTileSize)
        }
        streamManager.configureStreams(for: currentDisplayDescriptors())
        scheduleArrangementSync()
    }

    @objc
    private func handleRemoveFocused() {
        guard let focused = workspaceStore.focusedWorkspace else { return }
        guard focused.kind == .virtual else {
            NSSound.beep()
            return
        }

        guard displayManager.removeVirtualDisplay(displayID: focused.displayID) else {
            NSSound.beep()
            return
        }

        _ = workspaceStore.removeFocusedWorkspace()
        streamManager.configureStreams(for: currentDisplayDescriptors())
        scheduleArrangementSync()
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

    func canRemoveSelectedDisplay() -> Bool {
        guard !workspaceStore.selectedWorkspaceIDs.isEmpty else { return false }
        guard let focused = workspaceStore.focusedWorkspace else { return false }
        return focused.kind == .virtual
    }

    func beginShutdown(completion: @escaping () -> Void) {
        setTileStatus("Cleaning up displays...")
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
        let viewportSize = scrollView.contentView.bounds.size
        let width = max(1.0, viewportSize.width)
        let minHeight = max(1.0, viewportSize.height)
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
    }

    private func applyFixedReasonableTileSizing() {
        guard !workspaceStore.workspaces.isEmpty else { return }
        activeDynamicLayoutColumns = nil
        let sizes: [UUID: CGSize] = Dictionary(uniqueKeysWithValues:
            workspaceStore.workspaces.map { workspace in
                (workspace.id, gridView.reasonableFixedTileSize(for: workspace.displayPixelSize))
            }
        )
        workspaceStore.setTileSizes(sizes)
        scheduleArrangementSync()
    }

    private func openFullscreenForFocusedWorkspace() {
        if previewWindowController.isPresenting {
            previewWindowController.closePreview()
            return
        }

        guard let focused = workspaceStore.focusedWorkspace else {
            NSSound.beep()
            return
        }

        previewWindowController.presentImmersive(for: focused)
        pointerRouter.teleportToDisplay(displayID: focused.displayID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pointerRouter.teleportToDisplay(displayID: focused.displayID)
        }
    }

    private func refreshDynamicPresetLayoutForViewportIfNeeded() {
        guard shortcutManager.tileSizingMode == .dynamic,
              let columns = activeDynamicLayoutColumns,
              !workspaceStore.workspaces.isEmpty else {
            return
        }

        let viewportWidth = max(1.0, scrollView.contentView.bounds.width)
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
