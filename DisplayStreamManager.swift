import CoreGraphics
import CoreVideo
import Foundation
import IOSurface

private typealias CGDisplayFrameHandler = @convention(block) (Int32, UInt64, IOSurface?, CFTypeRef?) -> Void

@_silgen_name("CGDisplayStreamCreateWithDispatchQueue")
private func rawCGDisplayStreamCreateWithDispatchQueue(
    _ display: CGDirectDisplayID,
    _ outputWidth: Int,
    _ outputHeight: Int,
    _ pixelFormat: Int32,
    _ properties: CFDictionary?,
    _ queue: DispatchQueue,
    _ handler: CGDisplayFrameHandler?
) -> Unmanaged<CFTypeRef>?

@_silgen_name("CGDisplayStreamStart")
private func rawCGDisplayStreamStart(_ stream: CFTypeRef?) -> Int32

@_silgen_name("CGDisplayStreamStop")
private func rawCGDisplayStreamStop(_ stream: CFTypeRef?) -> Int32

final class DisplayStreamManager {
    private struct StreamEntry {
        let stream: CFTypeRef
        let handler: CGDisplayFrameHandler
        let width: Int
        let height: Int
    }

    private var entries: [CGDirectDisplayID: StreamEntry] = [:]
    private var latestSurfaces: [CGDirectDisplayID: IOSurface] = [:]
    private var targetDescriptors: [CGDirectDisplayID: DisplayDescriptor] = [:]

    private let controlQueue = DispatchQueue(label: "com.pointworks.workspacegrid.stream-control")
    private let callbackQueue = DispatchQueue(label: "com.pointworks.workspacegrid.stream-callback", qos: .userInteractive)
    private let surfaceQueue = DispatchQueue(label: "com.pointworks.workspacegrid.surface-store", attributes: .concurrent)

    var onFrame: (() -> Void)?
    var onDisplayFrame: ((CGDirectDisplayID, IOSurface) -> Void)?
    var onError: ((String) -> Void)?

    func stopAll() {
        controlQueue.sync {
            targetDescriptors.removeAll()
            let ids = Array(entries.keys)
            for displayID in ids {
                stopStream(for: displayID)
            }
        }
    }

    func configureStreams(for descriptors: [DisplayDescriptor]) {
        controlQueue.async { [weak self] in
            self?.reconfigure(descriptors: descriptors)
        }
    }

    func latestSurface(for displayID: CGDirectDisplayID) -> IOSurface? {
        surfaceQueue.sync {
            latestSurfaces[displayID]
        }
    }

    private func reconfigure(descriptors: [DisplayDescriptor]) {
        var uniqueByDisplay: [CGDirectDisplayID: DisplayDescriptor] = [:]
        for descriptor in descriptors where uniqueByDisplay[descriptor.displayID] == nil {
            uniqueByDisplay[descriptor.displayID] = descriptor
        }
        targetDescriptors = uniqueByDisplay

        let targetIDs = Set(uniqueByDisplay.keys)
        let existingIDs = Set(entries.keys)

        for removeID in existingIDs.subtracting(targetIDs) {
            stopStream(for: removeID)
        }

        for (displayID, descriptor) in uniqueByDisplay {
            let expectedWidth = Int(max(1.0, descriptor.pixelSize.width))
            let expectedHeight = Int(max(1.0, descriptor.pixelSize.height))

            if let existing = entries[displayID] {
                if existing.width != expectedWidth || existing.height != expectedHeight {
                    stopStream(for: displayID)
                    startStream(for: descriptor, attempt: 0)
                }
                continue
            }

            startStream(for: descriptor, attempt: 0)
        }
    }

    private func startStream(for descriptor: DisplayDescriptor, attempt: Int) {
        guard targetDescriptors[descriptor.displayID] != nil else {
            return
        }
        if entries[descriptor.displayID] != nil {
            return
        }

        let outputWidth = Int(max(1.0, descriptor.pixelSize.width))
        let outputHeight = Int(max(1.0, descriptor.pixelSize.height))
        let streamProperties: CFDictionary = [
            "kCGDisplayStreamShowCursor" as CFString: kCFBooleanTrue as Any,
        ] as CFDictionary

        let handler: CGDisplayFrameHandler = { [weak self] status, _, frameSurface, _ in
            guard let self else { return }
            guard status == 0, let frameSurface else { return }
            let displayID = descriptor.displayID

            self.surfaceQueue.sync(flags: .barrier) {
                self.latestSurfaces[displayID] = frameSurface
            }

            DispatchQueue.main.async {
                self.onDisplayFrame?(displayID, frameSurface)
                self.onFrame?()
            }
        }

        guard let streamRef = rawCGDisplayStreamCreateWithDispatchQueue(
            descriptor.displayID,
            outputWidth,
            outputHeight,
            Int32(kCVPixelFormatType_32BGRA),
            streamProperties,
            callbackQueue,
            handler
        ) else {
            if attempt < 30 {
                controlQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.startStream(for: descriptor, attempt: attempt + 1)
                }
            } else {
                DispatchQueue.main.async {
                    self.onError?("CGDisplayStream creation failed for display \(descriptor.displayID)")
                }
            }
            return
        }

        let stream = streamRef.takeRetainedValue()
        let startResult = rawCGDisplayStreamStart(stream)
        guard startResult == 0 else {
            if attempt < 30 {
                controlQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.startStream(for: descriptor, attempt: attempt + 1)
                }
            } else {
                DispatchQueue.main.async {
                    self.onError?("CGDisplayStream start failed for display \(descriptor.displayID): \(startResult)")
                }
            }
            return
        }

        entries[descriptor.displayID] = StreamEntry(
            stream: stream,
            handler: handler,
            width: outputWidth,
            height: outputHeight
        )
    }

    private func stopStream(for displayID: CGDirectDisplayID) {
        guard let entry = entries.removeValue(forKey: displayID) else { return }
        _ = entry.handler
        _ = entry.width
        _ = entry.height

        _ = rawCGDisplayStreamStop(entry.stream)

        _ = surfaceQueue.sync(flags: .barrier) {
            latestSurfaces.removeValue(forKey: displayID)
        }
    }
}
