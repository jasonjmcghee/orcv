import CoreGraphics
import Darwin
import Foundation

final class VirtualDisplayManager {
    private var virtualDisplays: [CGDirectDisplayID: CGVirtualDisplay] = [:]
    private var serialCounter: UInt32 = 100

    func physicalDisplayDescriptors() -> [DisplayDescriptor] {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success else {
            return []
        }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &ids, &displayCount) == .success else {
            return []
        }

        return ids.map { id in
            let width = CGFloat(CGDisplayPixelsWide(id))
            let height = CGFloat(CGDisplayPixelsHigh(id))
            return DisplayDescriptor(
                displayID: id,
                title: "Display \(id)",
                pixelSize: CGSize(width: width, height: height),
                kind: .physical
            )
        }
    }

    func desktopWorkspaceDescriptors() -> [DisplayDescriptor] {
        let physical = physicalDisplayDescriptors()
        guard !physical.isEmpty else {
            return []
        }

        let physicalByID = Dictionary(uniqueKeysWithValues: physical.map { ($0.displayID, $0) })
        guard let managed = managedDisplaySpaces() else {
            return physical
        }

        var workspaceTiles: [DisplayDescriptor] = []
        var desktopNumber = 1

        for displayEntry in managed {
            let displayID = resolveDisplayID(from: displayEntry, fallback: physical.first?.displayID ?? 0)
            let base = physicalByID[displayID] ?? physical.first!

            guard let spaces = displayEntry["Spaces"] as? [[String: Any]], !spaces.isEmpty else {
                continue
            }

            for _ in spaces {
                workspaceTiles.append(
                    DisplayDescriptor(
                        displayID: base.displayID,
                        title: "Desktop \(desktopNumber)",
                        pixelSize: base.pixelSize,
                        kind: .physical
                    )
                )
                desktopNumber += 1
            }
        }

        return workspaceTiles.isEmpty ? physical : workspaceTiles
    }

    func createVirtualDisplay(name: String, width: Int, height: Int, hidpi: Bool = true) -> DisplayDescriptor? {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        let requestedMaxWidth = width * (hidpi ? 2 : 1)
        let requestedMaxHeight = height * (hidpi ? 2 : 1)
        descriptor.maxPixelsWide = UInt32(max(8192, requestedMaxWidth))
        descriptor.maxPixelsHigh = UInt32(max(8192, requestedMaxHeight))
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        descriptor.serialNum = serialCounter
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x3456

        let display = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hidpi ? 1 : 0
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 60)
        ]

        guard display.apply(settings) else {
            return nil
        }

        serialCounter += 1
        let displayID = display.displayID
        virtualDisplays[displayID] = display

        return DisplayDescriptor(
            displayID: displayID,
            title: name,
            pixelSize: CGSize(width: width, height: height),
            kind: .virtual
        )
    }

    func removeVirtualDisplay(displayID: CGDirectDisplayID) -> Bool {
        guard virtualDisplays.removeValue(forKey: displayID) != nil else {
            return false
        }
        return true
    }

    func applyDisplayOrigins(_ origins: [CGDirectDisplayID: CGPoint]) -> Bool {
        guard !origins.isEmpty else { return true }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let configRef else {
            return false
        }

        for (displayID, origin) in origins {
            let x = Int32(origin.x.rounded())
            let y = Int32(origin.y.rounded())
            CGConfigureDisplayOrigin(configRef, displayID, x, y)
        }

        let result = CGCompleteDisplayConfiguration(configRef, .forSession)
        if result == .success {
            return true
        }
        CGCancelDisplayConfiguration(configRef)
        return false
    }

    private func managedDisplaySpaces() -> [[String: Any]]? {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_NOW) else {
            return nil
        }
        defer { dlclose(handle) }

        typealias MainConnectionIDFn = @convention(c) () -> UInt32
        typealias CopyManagedDisplaySpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>

        guard let connSym = dlsym(handle, "CGSMainConnectionID"),
              let copySym = dlsym(handle, "CGSCopyManagedDisplaySpaces") else {
            return nil
        }

        let connectionID = unsafeBitCast(connSym, to: MainConnectionIDFn.self)()
        let rawArray = unsafeBitCast(copySym, to: CopyManagedDisplaySpacesFn.self)(connectionID).takeRetainedValue()

        return (rawArray as NSArray).compactMap { $0 as? [String: Any] }
    }

    private func resolveDisplayID(from entry: [String: Any], fallback: CGDirectDisplayID) -> CGDirectDisplayID {
        let candidates: [Any?] = [
            entry["Display Identifier"],
            entry["DisplayID"],
            entry["Display ID"],
        ]

        for value in candidates {
            if let id = parseDisplayID(value) {
                return id
            }
        }
        return fallback
    }

    private func parseDisplayID(_ raw: Any?) -> CGDirectDisplayID? {
        if let number = raw as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        if let string = raw as? String {
            if let decimal = UInt32(string) {
                return CGDirectDisplayID(decimal)
            }
            if string.hasPrefix("0x"),
               let hex = UInt32(string.dropFirst(2), radix: 16) {
                return CGDirectDisplayID(hex)
            }
        }
        return nil
    }
}
