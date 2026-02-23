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

    private let scrollView = NSScrollView(frame: .zero)
    private let gridView = WorkspaceGridView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "Workspace Grid")
    private let subtitleLabel = NSTextField(labelWithString: "Drag tiles to rearrange displays. Click to focus. Control+Option+Space toggles teleport.")
    private let addButton = NSButton(title: "New Display", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Display", target: nil, action: nil)

    private var nextVirtualIndex: Int = 1
    private var localSwipeMonitor: Any?
    private var globalSwipeMonitor: Any?
    private var lastTeleportTime: TimeInterval = 0
    private var arrangementDebounceWorkItem: DispatchWorkItem?
    private var lastAppliedOrigins: [CGDirectDisplayID: CGPoint] = [:]
    private var isRestoringState = false

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
    }

    private func setupUI() {
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        addButton.bezelStyle = .rounded
        addButton.controlSize = .large
        addButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .large
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        gridView.frame = NSRect(x: 0, y: 0, width: 1200, height: 720)
        scrollView.documentView = gridView

        view.addSubview(scrollView)
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(addButton)
        view.addSubview(removeButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            removeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            removeButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),

            addButton.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -10),
            addButton.topAnchor.constraint(equalTo: removeButton.topAnchor),

            scrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
                    self?.applyFixedReasonableTileSizing()
                }
                self?.renderStore()
            }
        }

        gridView.onFocusRequest = { [weak self] workspaceID, pointInTile, frameInGrid in
            guard let self else { return }
            _ = pointInTile
            _ = frameInGrid

            self.workspaceStore.focus(workspaceID: workspaceID)
        }

        gridView.onResizeRequest = { [weak self] workspaceID, newSize in
            guard let self else { return }
            if self.shortcutManager.tileSizingMode == .fixed {
                self.applyFixedReasonableTileSizing()
            } else {
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

        streamManager.onError = { [weak self] message in
            DispatchQueue.main.async {
                self?.subtitleLabel.stringValue = message
            }
        }

        installSwipeMonitorsIfNeeded()
    }

    private func bootstrapDisplays() {
        if restoreStateIfAvailable() {
            return
        }

        workspaceStore.replaceWorkspaces(from: [])
        if hasScreenCaptureAccess {
            streamManager.configureStreams(for: [])
        } else {
            subtitleLabel.stringValue = "Screen Recording permission required for live display previews."
        }
    }

    private func renderStore() {
        gridView.workspaces = workspaceStore.workspaces
        gridView.focusedWorkspaceID = workspaceStore.focusedWorkspaceID
        let teleportHint = shortcutManager.displayLabel(for: .toggleTeleport)
        subtitleLabel.stringValue = "\(workspaceStore.workspaces.count) displays • Drag to move • Click to focus • \(teleportHint) toggles teleport."
        removeButton.isEnabled = workspaceStore.focusedWorkspace?.kind == .virtual
        layoutGridDocumentView()
    }

    @objc
    private func handleNewDisplay() {
        let name = "\(nextVirtualIndex)"
        nextVirtualIndex += 1

        guard let descriptor = displayManager.createVirtualDisplay(name: name, width: 1920, height: 1080, hidpi: true) else {
            NSSound.beep()
            return
        }

        workspaceStore.addWorkspace(from: descriptor)
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

    private func installSwipeMonitorsIfNeeded() {
        if localSwipeMonitor == nil {
            localSwipeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self else { return event }
                let consumed = self.handleNavigationEvent(event)
                return consumed ? nil : event
            }
        }
        if globalSwipeMonitor == nil {
            globalSwipeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                _ = self?.handleNavigationEvent(event)
            }
        }
    }

    private func handleNavigationEvent(_ event: NSEvent) -> Bool {
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
        }
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
        let sizes: [UUID: CGSize] = Dictionary(uniqueKeysWithValues:
            workspaceStore.workspaces.map { workspace in
                (workspace.id, gridView.reasonableFixedTileSize(for: workspace.displayPixelSize))
            }
        )
        workspaceStore.setTileSizes(sizes)
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
            workspaces: entries
        )
    }

    private func restoreStateIfAvailable() -> Bool {
        guard let persisted = stateStore.load(),
              persisted.version == 1,
              !persisted.workspaces.isEmpty else {
            return false
        }

        isRestoringState = true
        defer {
            isRestoringState = false
        }

        var restored: [Workspace] = []
        restored.reserveCapacity(persisted.workspaces.count)

        for (index, entry) in persisted.workspaces.enumerated() {
            let title = entry.title.isEmpty ? "\(index + 1)" : entry.title
            let width = max(640, entry.pixelWidth)
            let height = max(360, entry.pixelHeight)
            guard let descriptor = displayManager.createVirtualDisplay(
                name: title,
                width: width,
                height: height,
                hidpi: true
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

        workspaceStore.setWorkspaces(restored, focusedWorkspaceID: focusedID)
        nextVirtualIndex = max(persisted.nextVirtualIndex, restored.count + 1)

        streamManager.configureStreams(for: currentDisplayDescriptors())
        scheduleArrangementSync()
        scheduleStateSave()
        return true
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

}
