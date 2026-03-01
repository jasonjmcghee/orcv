import AppKit
import Foundation
import IOSurface
import QuartzCore

final class OrcvGridView: NSView {
    var workspaces: [Workspace] = [] {
        didSet {
            needsLayout = true
            needsDisplay = true
            syncTileLayers()
        }
    }

    var focusedWorkspaceID: UUID? {
        didSet {
            syncTileLayers()
            needsDisplay = true
        }
    }

    var selectedWorkspaceIDs: Set<UUID> = [] {
        didSet {
            syncTileLayers()
            needsDisplay = true
        }
    }

    var showsDisplayIDs = false {
        didSet {
            guard oldValue != showsDisplayIDs else { return }
            syncTileLayers()
            needsDisplay = true
        }
    }

    var layoutMode: WorkspaceLayoutMode = .canvas {
        didSet {
            guard oldValue != layoutMode else { return }
            previewOrderIDs = nil
            dragBaseOrderIDs = nil
            dragFrame = nil
            dragDidMove = false
            needsLayout = true
            needsDisplay = true
            syncTileLayers()
        }
    }

    var cameraMagnification: CGFloat = 1.0 {
        didSet {
            let clamped = max(0.01, cameraMagnification)
            if abs(clamped - cameraMagnification) > 0.0001 {
                cameraMagnification = clamped
                return
            }
            guard abs(oldValue - cameraMagnification) > 0.0001 else { return }
            needsLayout = true
            needsDisplay = true
            syncTileLayers()
        }
    }

    var cameraOrigin: CGPoint = .zero {
        didSet {
            guard abs(oldValue.x - cameraOrigin.x) > 0.0001 || abs(oldValue.y - cameraOrigin.y) > 0.0001 else { return }
            needsLayout = true
            needsDisplay = true
            syncTileLayers()
        }
    }

    var onFocusRequest: ((UUID, CGPoint, CGRect, NSEvent.ModifierFlags) -> Void)?
    var onResizeBegin: ((UUID) -> Void)?
    var onBackgroundClick: (() -> Void)?
    var onResizeRequest: ((UUID, CGSize) -> Void)?
    var onResizeCommit: ((UUID) -> Void)?
    var onReorderCommit: (([UUID]) -> Void)?
    var onCanvasMoveCommit: ((UUID, CGPoint) -> Void)?
    var onBackgroundWindowDragRequest: ((NSEvent) -> Void)?
    var onSwipeDown: (() -> Void)?
    var surfaceProvider: ((CGDirectDisplayID) -> IOSurface?)?
    var referenceProvider: ((Workspace) -> SurfaceReference)?
    var referenceSurfaceProvider: ((SurfaceReference) -> IOSurface?)?
    var suppressPreviewRebinds = false

    private struct TileLayers {
        let root: CALayer
        let preview: CALayer
        let overlay: CALayer
        let title: CATextLayer
        let subtitle: CATextLayer
        let handle: CAShapeLayer
        let border: CALayer
    }

    private var tileFrames: [UUID: CGRect] = [:]
    private var tileWorldFrames: [UUID: CGRect] = [:]
    private var tileLayers: [UUID: TileLayers] = [:]

    private var resizingWorkspaceID: UUID?
    private var resizeStartPoint: CGPoint = .zero
    private var resizeStartSize: CGSize = .zero
    private var dragWorkspaceID: UUID?
    private var dragPointerOffset: CGPoint = .zero
    private var dragFrame: CGRect?
    private var previewOrderIDs: [UUID]?
    private var dragBaseOrderIDs: [UUID]?
    private var dragDidMove = false
    private var reorderTargetFrame: CGRect?
    private let dragStartThreshold: CGFloat = 5.0
    private let reorderIndicatorLayer = CAShapeLayer()
    private var animateReflowNextSync = false

    private let horizontalPadding: CGFloat = 12.0
    private let verticalPadding: CGFloat = 0.0
    private let spacing: CGFloat = 8.0
    private let tileCornerRadius: CGFloat = 2.0
    private let wrapTolerance: CGFloat = 0.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        configureReorderIndicator()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        configureReorderIndicator()
    }

    override var isOpaque: Bool {
        false
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard workspaces.isEmpty else { return }

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        let text = "No displays yet."
        text.draw(in: bounds.insetBy(dx: 20, dy: 20), withAttributes: attrs)
    }

    func requiredContentHeight(forWidth width: CGFloat) -> CGFloat {
        _ = width
        return max(220.0, bounds.height)
    }

    func requiredContentWidth(forViewportWidth width: CGFloat) -> CGFloat {
        return max(width, bounds.width)
    }

    override func layout() {
        super.layout()
        recomputeTileFrames()
        syncTileLayers()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        let point = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isSelectionToggleClick = modifiers.contains(.command) || modifiers.contains(.shift)

        let byID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        for workspaceID in activeOrderIDs().reversed() {
            guard let workspace = byID[workspaceID],
                  let frame = tileFrames[workspace.id],
                  frame.contains(point) else { continue }

            let pointInTile = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
            if isSelectionToggleClick {
                onFocusRequest?(workspace.id, pointInTile, frame, modifiers)
                return
            }

            onFocusRequest?(workspace.id, pointInTile, frame, modifiers)

            dragWorkspaceID = workspace.id
            resizeStartPoint = point
            dragPointerOffset = pointInTile
            dragFrame = frame
            previewOrderIDs = nil
            dragBaseOrderIDs = nil
            reorderTargetFrame = nil
            dragDidMove = false
            return
        }

        onBackgroundClick?()
        onBackgroundWindowDragRequest?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let workspaceID = resizingWorkspaceID {
            let delta = CGPoint(x: point.x - resizeStartPoint.x, y: point.y - resizeStartPoint.y)
            let ratio = max(0.1, resizeStartSize.width / max(1.0, resizeStartSize.height))

            // View space is Y-up. Dragging downward makes delta.y negative, which should grow size.
            let widthDeltaFromX = delta.x
            let widthDeltaFromY = (-delta.y) * ratio
            let dominantWidthDelta = abs(widthDeltaFromX) >= abs(widthDeltaFromY) ? widthDeltaFromX : widthDeltaFromY

            let newWidth = max(1.0, resizeStartSize.width + dominantWidthDelta)
            let newSize = CGSize(width: newWidth, height: newWidth / ratio)
            onResizeRequest?(workspaceID, newSize)
            return
        }

        guard let draggedID = dragWorkspaceID,
              let initialFrame = tileFrames[draggedID] ?? dragFrame else { return }

        let distance = hypot(point.x - resizeStartPoint.x, point.y - resizeStartPoint.y)
        if !dragDidMove, distance < dragStartThreshold {
            return
        }
        if !dragDidMove {
            dragDidMove = true
            dragBaseOrderIDs = workspaces.map(\.id)
        }

        let baseOrder = dragBaseOrderIDs ?? workspaces.map(\.id)
        guard baseOrder.contains(draggedID) else { return }

        let newFrame = CGRect(
            x: point.x - dragPointerOffset.x,
            y: point.y - dragPointerOffset.y,
            width: initialFrame.width,
            height: initialFrame.height
        )
        dragFrame = newFrame

        if layoutMode == .canvas {
            syncTileLayers()
            return
        }

        let reorderIndex = targetIndexForDrag(
            draggedID: draggedID,
            pointer: point,
            orderIDs: baseOrder
        )
        let reordered = reorder(orderIDs: baseOrder, moving: draggedID, to: reorderIndex)
        if previewOrderIDs != reordered {
            previewOrderIDs = reordered
            animateReflowNextSync = true
            needsLayout = true
        } else {
            syncTileLayers()
        }
    }

    override func mouseUp(with event: NSEvent) {
        _ = event
        if let resizeWorkspaceID = resizingWorkspaceID {
            resizingWorkspaceID = nil
            onResizeCommit?(resizeWorkspaceID)
            return
        }

        guard let draggedID = dragWorkspaceID else { return }
        defer {
            dragWorkspaceID = nil
            dragFrame = nil
            reorderTargetFrame = nil
            previewOrderIDs = nil
            dragBaseOrderIDs = nil
            dragDidMove = false
            animateReflowNextSync = false
            needsLayout = true
            needsDisplay = true
        }

        guard dragDidMove else { return }

        if layoutMode == .canvas {
            if let dragFrame {
                onCanvasMoveCommit?(draggedID, worldPoint(fromViewportPoint: dragFrame.origin))
            }
            return
        }

        guard let previewOrderIDs else { return }
        if previewOrderIDs.contains(draggedID) {
            onReorderCommit?(previewOrderIDs)
        }
    }

    override func swipe(with event: NSEvent) {
        if event.deltaY < 0 {
            onSwipeDown?()
        }
    }

    func hitTestWorkspace(at pointInView: CGPoint) -> (workspaceID: UUID, pointInTile: CGPoint, frameInGrid: CGRect)? {
        for workspaceID in activeOrderIDs().reversed() {
            guard let frame = tileFrames[workspaceID], frame.contains(pointInView) else { continue }
            let pointInTile = CGPoint(x: pointInView.x - frame.minX, y: pointInView.y - frame.minY)
            return (workspaceID: workspaceID, pointInTile: pointInTile, frameInGrid: frame)
        }
        return nil
    }

    func frameForWorkspaceInGrid(_ workspaceID: UUID) -> CGRect? {
        tileFrames[workspaceID]
    }

    func frameForWorkspaceInWorld(_ workspaceID: UUID) -> CGRect? {
        tileWorldFrames[workspaceID]
    }

    func canvasInitialViewportOrigin(for viewportSize: CGSize) -> CGPoint {
        let worldFrames = canvasWorldFrames(for: activeOrderIDs())
        guard !worldFrames.isEmpty else {
            return CGPoint(
                x: -viewportSize.width / (2.0 * max(0.01, cameraMagnification)),
                y: -viewportSize.height / (2.0 * max(0.01, cameraMagnification))
            )
        }

        let minX = worldFrames.values.map(\.minX).min() ?? 0
        let maxX = worldFrames.values.map(\.maxX).max() ?? 0
        let minY = worldFrames.values.map(\.minY).min() ?? 0
        let maxY = worldFrames.values.map(\.maxY).max() ?? 0
        let worldCenter = CGPoint(x: (minX + maxX) / 2.0, y: (minY + maxY) / 2.0)
        return CGPoint(
            x: worldCenter.x - viewportSize.width / (2.0 * max(0.01, cameraMagnification)),
            y: worldCenter.y - viewportSize.height / (2.0 * max(0.01, cameraMagnification))
        )
    }

    func canvasViewportOriginForWorldOrigin(viewportSize: CGSize) -> CGPoint {
        return CGPoint(
            x: -viewportSize.width / (2.0 * max(0.01, cameraMagnification)),
            y: -viewportSize.height / (2.0 * max(0.01, cameraMagnification))
        )
    }

    func frameForWorkspaceInScreen(_ workspaceID: UUID) -> CGRect? {
        guard let window, let frame = tileFrames[workspaceID] else { return nil }
        let frameInWindow = convert(frame, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    func refreshPreviews() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for workspace in workspaces {
            guard let layers = tileLayers[workspace.id] else { continue }
            if layers.preview.contents == nil {
                applyPreview(for: workspace, layers: layers)
            }
        }
        CATransaction.commit()
    }

    func refreshPreviews(for displayID: CGDirectDisplayID) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for workspace in workspaces where workspace.displayID == displayID {
            guard let layers = tileLayers[workspace.id] else { continue }
            if !suppressPreviewRebinds || layers.preview.contents == nil {
                applyPreview(for: workspace, layers: layers)
            }
        }
        CATransaction.commit()
    }

    func tileSize(for pixelSize: CGSize, columns: Int) -> CGSize {
        let safeColumns = max(1, columns)
        let availableWidth = max(300.0, bounds.width - horizontalPadding * 2.0)
        let totalSpacing = CGFloat(max(0, safeColumns - 1)) * spacing
        let targetWidth = max(160.0, (availableWidth - totalSpacing) / CGFloat(safeColumns))
        return normalizedTileSize(targetWidth: targetWidth, pixelSize: pixelSize, limitMaxHeight: false)
    }

    func reasonableFixedTileSize(for pixelSize: CGSize) -> CGSize {
        normalizedTileSize(targetWidth: 420.0, pixelSize: pixelSize, limitMaxHeight: true)
    }

    private func recomputeTileFrames() {
        let worldFrames = canvasWorldFrames(
            for: activeOrderIDs(),
            layoutWidth: max(1.0, bounds.width / max(0.01, cameraMagnification))
        )
        tileWorldFrames = worldFrames
        tileFrames = viewportFrames(fromWorldFrames: worldFrames)
    }

    private func syncTileLayers() {
        guard let hostLayer = layer else { return }

        let visibleIDs = Set(workspaces.map(\.id))
        for (id, layers) in tileLayers where !visibleIDs.contains(id) {
            layers.root.removeFromSuperlayer()
            tileLayers.removeValue(forKey: id)
        }

        let animateReflow = animateReflowNextSync
        animateReflowNextSync = false
        CATransaction.begin()
        CATransaction.setDisableActions(!animateReflow)
        if animateReflow {
            CATransaction.setAnimationDuration(0.16)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        }

        for workspace in orderedWorkspaces() {
            guard let frame = tileFrames[workspace.id] else { continue }
            let layers = tileLayers[workspace.id] ?? makeTileLayers(hostLayer: hostLayer)
            tileLayers[workspace.id] = layers

            let isFocused = workspace.id == focusedWorkspaceID
            let isSelected = selectedWorkspaceIDs.contains(workspace.id)
            let isDragged = workspace.id == dragWorkspaceID

            if isDragged, let dragFrame {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layers.root.frame = dragFrame
                CATransaction.commit()
            } else {
                layers.root.frame = frame
            }
            layers.root.zPosition = isDragged ? 10.0 : 0.0
            layers.preview.frame = layers.root.bounds.insetBy(dx: 1.5, dy: 1.5)
            layers.overlay.frame = layers.root.bounds
            layers.overlay.backgroundColor = NSColor.black.withAlphaComponent(isDragged ? 0.12 : (isSelected ? 0.18 : 0.25)).cgColor
            layers.border.frame = layers.root.bounds

            layers.title.frame = CGRect(x: 12, y: layers.root.bounds.height - 24, width: layers.root.bounds.width - 24, height: 18)
            if showsDisplayIDs {
                layers.title.string = "\(workspace.displayID)"
                layers.title.isHidden = false
            } else {
                layers.title.string = ""
                layers.title.isHidden = true
            }
            layers.subtitle.string = ""
            layers.subtitle.isHidden = true

            if isFocused {
                layers.border.borderColor = NSColor.controlAccentColor.cgColor
                layers.border.borderWidth = 2.0
            } else if isSelected {
                layers.border.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
                layers.border.borderWidth = 1.5
            } else {
                layers.border.borderColor = NSColor.separatorColor.cgColor
                layers.border.borderWidth = 1.0
            }

            let handleRect = CGRect(x: layers.root.bounds.width - 16, y: 0, width: 16, height: 16)
            let handlePath = CGMutablePath()
            handlePath.move(to: CGPoint(x: handleRect.minX + 3, y: handleRect.minY + 3))
            handlePath.addLine(to: CGPoint(x: handleRect.maxX - 3, y: handleRect.minY + 3))
            handlePath.addLine(to: CGPoint(x: handleRect.maxX - 3, y: handleRect.maxY - 3))
            layers.handle.path = handlePath
            layers.handle.isHidden = true

            if !suppressPreviewRebinds || layers.preview.contents == nil {
                applyPreview(for: workspace, layers: layers)
            }
        }

        updateReorderIndicator(hostLayer: hostLayer)
        CATransaction.commit()
    }

    private func makeTileLayers(hostLayer: CALayer) -> TileLayers {
        let root = CALayer()
        root.cornerRadius = tileCornerRadius
        root.masksToBounds = true

        let preview = CALayer()
        preview.cornerRadius = tileCornerRadius - 1.5
        preview.masksToBounds = true
        // Keep tile-space -> display-space mapping linear for teleport math.
        // Aspect-fill crops and breaks coordinate correspondence.
        preview.contentsGravity = .resize
        preview.minificationFilter = .trilinear
        preview.magnificationFilter = .linear

        let overlay = CALayer()
        overlay.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor

        let title = CATextLayer()
        title.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        title.fontSize = 14
        title.foregroundColor = NSColor.labelColor.cgColor
        title.alignmentMode = .left

        let subtitle = CATextLayer()
        subtitle.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        subtitle.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitle.fontSize = 12
        subtitle.foregroundColor = NSColor.secondaryLabelColor.cgColor
        subtitle.alignmentMode = .left
        subtitle.isHidden = true

        let handle = CAShapeLayer()
        handle.strokeColor = NSColor.tertiaryLabelColor.cgColor
        handle.fillColor = nil
        handle.lineWidth = 1.5

        let border = CALayer()
        border.cornerRadius = tileCornerRadius
        border.backgroundColor = NSColor.clear.cgColor

        root.addSublayer(preview)
        root.addSublayer(overlay)
        root.addSublayer(title)
        root.addSublayer(subtitle)
        root.addSublayer(handle)
        root.addSublayer(border)

        hostLayer.addSublayer(root)

        return TileLayers(root: root, preview: preview, overlay: overlay, title: title, subtitle: subtitle, handle: handle, border: border)
    }

    private func applyPreview(for workspace: Workspace, layers: TileLayers) {
        let reference = referenceProvider?(workspace) ?? SurfaceReference(displayID: workspace.displayID)
        let surface = referenceSurfaceProvider?(reference) ?? surfaceProvider?(workspace.displayID)
        if let surface {
            layers.preview.contents = surface
            layers.preview.contentsRect = reference.region.layerContentsRect
            layers.preview.backgroundColor = NSColor.clear.cgColor
        } else {
            layers.preview.contents = nil
            layers.preview.contentsRect = ReferenceRegion.fullDisplay.layerContentsRect
            let isFocused = workspace.id == focusedWorkspaceID
            layers.preview.backgroundColor = (isFocused
                ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                : NSColor.controlBackgroundColor).cgColor
        }
    }

    private func configureReorderIndicator() {
        reorderIndicatorLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        reorderIndicatorLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        reorderIndicatorLayer.lineDashPattern = [8, 5]
        reorderIndicatorLayer.lineWidth = 2.0
        reorderIndicatorLayer.isHidden = true
    }

    private func activeOrderIDs() -> [UUID] {
        if let previewOrderIDs { return previewOrderIDs }
        return workspaces.map(\.id)
    }

    private func orderedWorkspaces() -> [Workspace] {
        let byID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        return activeOrderIDs().compactMap { byID[$0] }
    }

    private func reorder(orderIDs: [UUID], moving workspaceID: UUID, to targetIndex: Int) -> [UUID] {
        guard let fromIndex = orderIDs.firstIndex(of: workspaceID) else { return orderIDs }
        var reordered = orderIDs
        reordered.remove(at: fromIndex)
        let clampedIndex = max(0, min(targetIndex, reordered.count))
        reordered.insert(workspaceID, at: clampedIndex)
        return reordered
    }

    private func targetIndexForDrag(
        draggedID: UUID,
        pointer: CGPoint,
        orderIDs: [UUID]
    ) -> Int {
        let remaining = orderIDs.filter { $0 != draggedID }
        guard !remaining.isEmpty else { return 0 }

        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for index in 0...remaining.count {
            var candidate = remaining
            candidate.insert(draggedID, at: index)
            let candidateFrames = layoutFrames(for: candidate)
            guard let frame = candidateFrames[draggedID] else { continue }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let distance = hypot(center.x - pointer.x, center.y - pointer.y)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        return bestIndex
    }

    private func layoutFrames(for orderIDs: [UUID], layoutWidth: CGFloat? = nil) -> [UUID: CGRect] {
        let worldFrames = canvasWorldFrames(for: orderIDs, layoutWidth: layoutWidth)
        return viewportFrames(fromWorldFrames: worldFrames)
    }

    private func canvasLayoutFrames(for orderIDs: [UUID], layoutWidth: CGFloat? = nil) -> [UUID: CGRect] {
        let worldFrames = canvasWorldFrames(for: orderIDs, layoutWidth: layoutWidth)
        return viewportFrames(fromWorldFrames: worldFrames)
    }

    private func canvasWorldFrames(for orderIDs: [UUID], layoutWidth: CGFloat? = nil) -> [UUID: CGRect] {
        let byID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let fallbackOrigins = canvasFallbackOrigins(for: orderIDs, layoutWidth: layoutWidth)
        var frames: [UUID: CGRect] = [:]

        for workspaceID in orderIDs {
            guard let workspace = byID[workspaceID] else { continue }
            let worldOrigin = workspace.canvasOrigin ?? fallbackOrigins[workspaceID] ?? CGPoint(x: horizontalPadding, y: verticalPadding)
            frames[workspaceID] = CGRect(origin: worldOrigin, size: workspace.tileSize)
        }
        return frames
    }

    private func canvasFallbackOrigins(for orderIDs: [UUID], layoutWidth: CGFloat?) -> [UUID: CGPoint] {
        let byID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        let width = max(1.0, layoutWidth ?? bounds.width)
        let availableWidth = max(300.0, width - horizontalPadding * 2.0)
        var origins: [UUID: CGPoint] = [:]

        var x = horizontalPadding
        var y = verticalPadding
        var rowHeight: CGFloat = 0.0

        for workspaceID in orderIDs {
            guard let workspace = byID[workspaceID] else { continue }
            let tileSize = workspace.tileSize

            if x > horizontalPadding && x + tileSize.width > horizontalPadding + availableWidth + wrapTolerance {
                x = horizontalPadding
                y += rowHeight + spacing
                rowHeight = 0.0
            }

            origins[workspaceID] = CGPoint(x: x, y: y)
            x += tileSize.width + spacing
            rowHeight = max(rowHeight, tileSize.height)
        }

        return origins
    }

    private func updateReorderIndicator(hostLayer: CALayer) {
        _ = hostLayer
        reorderTargetFrame = nil
        reorderIndicatorLayer.isHidden = true
    }

    private func normalizedTileSize(targetWidth: CGFloat, pixelSize: CGSize, limitMaxHeight: Bool) -> CGSize {
        let ratio = max(0.1, pixelSize.width / max(1.0, pixelSize.height))
        let minHeight = max(140.0, 220.0 / ratio)
        let maxHeight = min(900.0, 1200.0 / ratio)
        var targetHeight = targetWidth / ratio
        if limitMaxHeight {
            targetHeight = max(minHeight, min(maxHeight, targetHeight))
        } else {
            targetHeight = max(minHeight, targetHeight)
        }
        return CGSize(width: targetHeight * ratio, height: targetHeight)
    }

    private func viewportFrames(fromWorldFrames worldFrames: [UUID: CGRect]) -> [UUID: CGRect] {
        let scale = max(0.01, cameraMagnification)
        var frames: [UUID: CGRect] = [:]
        for (workspaceID, worldFrame) in worldFrames {
            let origin = CGPoint(
                x: (worldFrame.origin.x - cameraOrigin.x) * scale,
                y: (worldFrame.origin.y - cameraOrigin.y) * scale
            )
            let size = CGSize(width: worldFrame.width * scale, height: worldFrame.height * scale)
            frames[workspaceID] = CGRect(origin: origin, size: size)
        }
        return frames
    }

    private func worldPoint(fromViewportPoint point: CGPoint) -> CGPoint {
        let scale = max(0.01, cameraMagnification)
        return CGPoint(
            x: point.x / scale + cameraOrigin.x,
            y: point.y / scale + cameraOrigin.y
        )
    }
}
