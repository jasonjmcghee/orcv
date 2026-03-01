import CoreGraphics
import Foundation

final class WorkspaceStore {
    private(set) var workspaces: [Workspace] = []
    private(set) var focusedWorkspaceID: UUID?
    private(set) var selectedWorkspaceIDs: Set<UUID> = []

    var onDidChange: (() -> Void)?

    func replaceWorkspaces(from descriptors: [DisplayDescriptor]) {
        let mapped = descriptors.map { descriptor in
            Workspace(
                id: UUID(),
                displayID: descriptor.displayID,
                title: descriptor.title,
                kind: descriptor.kind,
                displayPixelSize: descriptor.pixelSize,
                tileSize: WorkspaceStore.defaultTileSize(for: descriptor.pixelSize),
                canvasOrigin: nil
            )
        }

        workspaces = mapped.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        focusedWorkspaceID = workspaces.first?.id
        selectedWorkspaceIDs = focusedWorkspaceID.map { [$0] } ?? []
        onDidChange?()
    }

    func setWorkspaces(_ restored: [Workspace], focusedWorkspaceID preferredFocus: UUID?) {
        workspaces = restored
        if let preferredFocus, restored.contains(where: { $0.id == preferredFocus }) {
            focusedWorkspaceID = preferredFocus
        } else {
            focusedWorkspaceID = restored.first?.id
        }
        selectedWorkspaceIDs = focusedWorkspaceID.map { [$0] } ?? []
        onDidChange?()
    }

    @discardableResult
    func addWorkspace(
        from descriptor: DisplayDescriptor,
        tileSize: CGSize? = nil,
        at index: Int? = nil,
        workspaceID: UUID = UUID()
    ) -> Workspace {
        let workspace = Workspace(
            id: workspaceID,
            displayID: descriptor.displayID,
            title: descriptor.title,
            kind: descriptor.kind,
            displayPixelSize: descriptor.pixelSize,
            tileSize: tileSize ?? WorkspaceStore.defaultTileSize(for: descriptor.pixelSize),
            canvasOrigin: nil
        )

        if let index {
            let insertionIndex = max(0, min(index, workspaces.count))
            workspaces.insert(workspace, at: insertionIndex)
        } else {
            workspaces.append(workspace)
        }
        focusedWorkspaceID = workspace.id
        selectedWorkspaceIDs = [workspace.id]
        onDidChange?()
        return workspace
    }

    func focus(workspaceID: UUID) {
        guard workspaces.contains(where: { $0.id == workspaceID }) else { return }
        focusedWorkspaceID = workspaceID
        onDidChange?()
    }

    func selectOnly(workspaceID: UUID) {
        guard workspaces.contains(where: { $0.id == workspaceID }) else { return }
        focusedWorkspaceID = workspaceID
        selectedWorkspaceIDs = [workspaceID]
        onDidChange?()
    }

    func toggleSelection(workspaceID: UUID) {
        guard workspaces.contains(where: { $0.id == workspaceID }) else { return }
        if selectedWorkspaceIDs.contains(workspaceID) {
            selectedWorkspaceIDs.remove(workspaceID)
            if selectedWorkspaceIDs.isEmpty {
                focusedWorkspaceID = nil
            } else if focusedWorkspaceID == workspaceID {
                focusedWorkspaceID = selectedWorkspaceIDs.first
            }
        } else {
            selectedWorkspaceIDs.insert(workspaceID)
            focusedWorkspaceID = workspaceID
        }
        onDidChange?()
    }

    func clearSelection() {
        selectedWorkspaceIDs.removeAll()
        focusedWorkspaceID = nil
        onDidChange?()
    }

    func normalizeTileSizesForCurrentDisplays() {
        guard !workspaces.isEmpty else { return }
        var changed = false
        for i in workspaces.indices {
            let current = workspaces[i].tileSize
            let pixel = workspaces[i].displayPixelSize
            let ratio = max(0.1, pixel.width / max(1.0, pixel.height))
            let minHeight = max(140.0, 220.0 / ratio)
            let maxHeight = min(900.0, 1200.0 / ratio)
            var targetHeight = current.height
            if !targetHeight.isFinite || targetHeight <= 0 {
                targetHeight = 360.0 / ratio
            }
            targetHeight = max(minHeight, min(maxHeight, targetHeight))
            let normalized = CGSize(width: targetHeight * ratio, height: targetHeight)
            if abs(current.width - normalized.width) > 0.5 || abs(current.height - normalized.height) > 0.5 {
                workspaces[i].tileSize = normalized
                changed = true
            }
        }
        if changed {
            onDidChange?()
        }
    }

    func setCanvasOrigins(_ originsByWorkspaceID: [UUID: CGPoint]) {
        guard !originsByWorkspaceID.isEmpty else { return }
        var changed = false
        for i in workspaces.indices {
            guard let origin = originsByWorkspaceID[workspaces[i].id] else { continue }
            if let current = workspaces[i].canvasOrigin {
                if abs(current.x - origin.x) <= 0.5, abs(current.y - origin.y) <= 0.5 {
                    continue
                }
            }
            workspaces[i].canvasOrigin = origin
            changed = true
        }
        if changed {
            onDidChange?()
        }
    }

    func updateCanvasOrigin(workspaceID: UUID, origin: CGPoint) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        if let current = workspaces[index].canvasOrigin {
            if abs(current.x - origin.x) <= 0.5, abs(current.y - origin.y) <= 0.5 {
                return
            }
        }
        workspaces[index].canvasOrigin = origin
        onDidChange?()
    }

    @discardableResult
    func updateDisplayPixelSize(displayID: CGDirectDisplayID, pixelSize: CGSize) -> UUID? {
        guard let index = workspaces.firstIndex(where: { $0.displayID == displayID }) else { return nil }
        let current = workspaces[index].displayPixelSize
        if abs(current.width - pixelSize.width) <= 0.5, abs(current.height - pixelSize.height) <= 0.5 {
            return nil
        }
        workspaces[index].displayPixelSize = pixelSize
        onDidChange?()
        return workspaces[index].id
    }

    func reorderWorkspaces(_ orderedIDs: [UUID]) {
        guard orderedIDs.count == workspaces.count else { return }
        let idSet = Set(orderedIDs)
        guard idSet.count == workspaces.count else { return }
        guard Set(workspaces.map(\.id)) == idSet else { return }

        let byID = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) })
        workspaces = orderedIDs.compactMap { byID[$0] }
        selectedWorkspaceIDs = selectedWorkspaceIDs.intersection(Set(orderedIDs))
        onDidChange?()
    }

    func removeFocusedWorkspace() -> Workspace? {
        guard let focusedID = focusedWorkspaceID,
              let index = workspaces.firstIndex(where: { $0.id == focusedID }) else {
            return nil
        }

        let removed = workspaces.remove(at: index)
        focusedWorkspaceID = workspaces.first?.id
        selectedWorkspaceIDs.remove(removed.id)
        if selectedWorkspaceIDs.isEmpty, let focusedWorkspaceID {
            selectedWorkspaceIDs = [focusedWorkspaceID]
        }
        onDidChange?()
        return removed
    }

    @discardableResult
    func removeWorkspace(id: UUID) -> (workspace: Workspace, index: Int)? {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let removed = workspaces.remove(at: index)
        selectedWorkspaceIDs.remove(removed.id)

        if focusedWorkspaceID == removed.id {
            focusedWorkspaceID = workspaces.first?.id
        }
        if selectedWorkspaceIDs.isEmpty, let focusedWorkspaceID {
            selectedWorkspaceIDs = [focusedWorkspaceID]
        }

        onDidChange?()
        return (removed, index)
    }

    func indexOfWorkspace(id: UUID) -> Int? {
        workspaces.firstIndex(where: { $0.id == id })
    }

    func workspace(with id: UUID) -> Workspace? {
        workspaces.first(where: { $0.id == id })
    }

    var focusedWorkspace: Workspace? {
        guard let focusedWorkspaceID else { return nil }
        return workspace(with: focusedWorkspaceID)
    }

    var selectedWorkspaces: [Workspace] {
        workspaces.filter { selectedWorkspaceIDs.contains($0.id) }
    }

    func focusNextWorkspace() {
        guard !workspaces.isEmpty else { return }
        guard let currentFocusedID = focusedWorkspaceID,
              let currentIndex = workspaces.firstIndex(where: { $0.id == currentFocusedID }) else {
            focusedWorkspaceID = workspaces.first?.id
            if let focusedWorkspaceID {
                selectedWorkspaceIDs = [focusedWorkspaceID]
            }
            onDidChange?()
            return
        }
        let nextIndex = (currentIndex + 1) % workspaces.count
        focusedWorkspaceID = workspaces[nextIndex].id
        if let focusedWorkspaceID {
            selectedWorkspaceIDs = [focusedWorkspaceID]
        }
        onDidChange?()
    }

    func focusPreviousWorkspace() {
        guard !workspaces.isEmpty else { return }
        guard let currentFocusedID = focusedWorkspaceID,
              let currentIndex = workspaces.firstIndex(where: { $0.id == currentFocusedID }) else {
            focusedWorkspaceID = workspaces.first?.id
            if let focusedWorkspaceID {
                selectedWorkspaceIDs = [focusedWorkspaceID]
            }
            onDidChange?()
            return
        }
        let previousIndex = (currentIndex - 1 + workspaces.count) % workspaces.count
        focusedWorkspaceID = workspaces[previousIndex].id
        if let focusedWorkspaceID {
            selectedWorkspaceIDs = [focusedWorkspaceID]
        }
        onDidChange?()
    }

    private static func defaultTileSize(for pixelSize: CGSize) -> CGSize {
        let baseWidth: CGFloat = 360.0
        let aspect = pixelSize.height > 0 ? pixelSize.width / pixelSize.height : (16.0 / 9.0)
        return CGSize(width: baseWidth, height: baseWidth / max(0.6, min(2.4, aspect)))
    }
}
