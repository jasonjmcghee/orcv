import AppKit
import CoreGraphics
import Foundation

enum RecordedLocationMode {
    case absolute(CGPoint)
    case relative(CGPoint)
}

struct RecordedInputEvent {
    let delay: TimeInterval
    let type: CGEventType
    let flags: CGEventFlags
    let locationMode: RecordedLocationMode?

    let keyCode: CGKeyCode?
    let mouseButton: CGMouseButton
    let clickState: Int64

    let scrollDeltaY: Int32
    let scrollDeltaX: Int32
    let scrollPointDeltaY: Int32
    let scrollPointDeltaX: Int32
    let scrollIsContinuous: Bool
}

final class InputMacroEngine {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var virtualDisplayIDs: Set<CGDirectDisplayID> = []
    private var lastEventTime: TimeInterval = 0

    private(set) var recordedEvents: [RecordedInputEvent] = []
    private(set) var isRecording = false
    private(set) var isReplaying = false
    private(set) var statusMessage: String = "Idle"

    var onStateChanged: (() -> Void)?

    private let recordableTypes: Set<CGEventType> = [
        .leftMouseDown,
        .leftMouseUp,
        .leftMouseDragged,
        .rightMouseDown,
        .rightMouseUp,
        .rightMouseDragged,
        .otherMouseDown,
        .otherMouseUp,
        .otherMouseDragged,
        .scrollWheel,
        .keyDown,
        .keyUp,
    ]

    // Fast replay profile: preserve ordering but cap waits aggressively.
    private let keyDelayCap: TimeInterval = 0.012
    private let mouseDelayCap: TimeInterval = 0.006
    private let scrollDelayCap: TimeInterval = 0.008
    private let otherDelayCap: TimeInterval = 0.010

    // Drag coalescing thresholds for fast replay.
    private let minDragDistanceAbsolute: CGFloat = 8.0
    private let minDragDistanceNormalized: CGFloat = 0.004

    deinit {
        stopRecording()
    }

    var recordedEventCount: Int {
        recordedEvents.count
    }

    @discardableResult
    func startRecording(virtualDisplayIDs: Set<CGDirectDisplayID>) -> Bool {
        guard !isRecording, !isReplaying else { return false }

        stopRecording()
        recordedEvents.removeAll(keepingCapacity: true)
        self.virtualDisplayIDs = virtualDisplayIDs

        let mask = eventMask(for: recordableTypes)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            statusMessage = "Recording failed: grant Input Monitoring permission."
            onStateChanged?()
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            statusMessage = "Recording failed: could not create tap source."
            onStateChanged?()
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        isRecording = true
        lastEventTime = ProcessInfo.processInfo.systemUptime
        statusMessage = "Recording..."
        onStateChanged?()
        return true
    }

    func stopRecording() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil

        if isRecording {
            isRecording = false
            statusMessage = "Recorded \(recordedEvents.count) events"
            onStateChanged?()
        }
    }

    func replaySequential(on targetDisplayIDs: [CGDirectDisplayID]) {
        guard !isRecording, !isReplaying else { return }
        guard !recordedEvents.isEmpty else {
            statusMessage = "No recording"
            onStateChanged?()
            return
        }
        guard !targetDisplayIDs.isEmpty else {
            statusMessage = "No replay targets selected"
            onStateChanged?()
            return
        }

        guard AXIsProcessTrusted() else {
            statusMessage = "Replay failed: grant Accessibility permission."
            onStateChanged?()
            return
        }

        isReplaying = true
        statusMessage = "Replaying \(recordedEvents.count) events to \(targetDisplayIDs.count) target(s)..."
        onStateChanged?()

        let events = recordedEvents
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }

            for (index, targetDisplayID) in targetDisplayIDs.enumerated() {
                let targetIndex = index + 1
                DispatchQueue.main.async {
                    self.statusMessage = "Replaying target \(targetIndex)/\(targetDisplayIDs.count)..."
                    self.onStateChanged?()
                }

                self.replay(events: events, targetDisplayID: targetDisplayID)
                usleep(120_000)
            }

            DispatchQueue.main.async {
                self.isReplaying = false
                self.statusMessage = "Replay complete"
                self.onStateChanged?()
            }
        }
    }

    private func replay(events: [RecordedInputEvent], targetDisplayID: CGDirectDisplayID) {
        let fastEvents = buildFastReplayEvents(from: events)
        for event in fastEvents {
            let sleepMicros = max(0, Int(event.delay * 1_000_000.0))
            if sleepMicros > 0 {
                usleep(useconds_t(min(sleepMicros, Int(useconds_t.max))))
            }

            guard let replayEvent = makeReplayEvent(from: event, targetDisplayID: targetDisplayID) else {
                continue
            }
            replayEvent.post(tap: .cghidEventTap)
        }
    }

    private func buildFastReplayEvents(from events: [RecordedInputEvent]) -> [RecordedInputEvent] {
        guard !events.isEmpty else { return [] }

        var keepMask = Array(repeating: true, count: events.count)

        var dragRunStart: Int?
        for i in events.indices {
            if isDragEvent(events[i].type) {
                if dragRunStart == nil {
                    dragRunStart = i
                }
            } else if let runStartIndex = dragRunStart {
                applyDragCoalescing(events: events, keepMask: &keepMask, runStart: runStartIndex, runEnd: i - 1)
                dragRunStart = nil
            }
        }
        if let dragRunStart {
            applyDragCoalescing(events: events, keepMask: &keepMask, runStart: dragRunStart, runEnd: events.count - 1)
        }

        var fast: [RecordedInputEvent] = []
        fast.reserveCapacity(events.count)

        var pendingDelay: TimeInterval = 0
        for i in events.indices {
            pendingDelay += events[i].delay
            guard keepMask[i] else { continue }
            let capped = min(delayCap(for: events[i].type), max(0, pendingDelay))
            fast.append(events[i].withDelay(capped))
            pendingDelay = 0
        }

        return fast
    }

    private func applyDragCoalescing(
        events: [RecordedInputEvent],
        keepMask: inout [Bool],
        runStart: Int,
        runEnd: Int
    ) {
        guard runStart <= runEnd else { return }

        for i in runStart...runEnd {
            keepMask[i] = false
        }
        keepMask[runStart] = true
        keepMask[runEnd] = true

        var lastKeptLocation = events[runStart].locationMode
        if runEnd <= runStart + 1 {
            return
        }

        for i in (runStart + 1)..<runEnd {
            let distance = locationDistance(from: lastKeptLocation, to: events[i].locationMode)
            if distance >= dragDistanceThreshold(for: events[i].locationMode) {
                keepMask[i] = true
                lastKeptLocation = events[i].locationMode
            }
        }
    }

    private func delayCap(for type: CGEventType) -> TimeInterval {
        if type == .keyDown || type == .keyUp {
            return keyDelayCap
        }
        if isDragEvent(type) || isMouseClickEvent(type) {
            return mouseDelayCap
        }
        if type == .scrollWheel {
            return scrollDelayCap
        }
        return otherDelayCap
    }

    private func isMouseClickEvent(_ type: CGEventType) -> Bool {
        type == .leftMouseDown
            || type == .leftMouseUp
            || type == .rightMouseDown
            || type == .rightMouseUp
            || type == .otherMouseDown
            || type == .otherMouseUp
    }

    private func isDragEvent(_ type: CGEventType) -> Bool {
        type == .leftMouseDragged
            || type == .rightMouseDragged
            || type == .otherMouseDragged
    }

    private func dragDistanceThreshold(for mode: RecordedLocationMode?) -> CGFloat {
        switch mode {
        case .relative:
            return minDragDistanceNormalized
        default:
            return minDragDistanceAbsolute
        }
    }

    private func locationDistance(from lhs: RecordedLocationMode?, to rhs: RecordedLocationMode?) -> CGFloat {
        switch (lhs, rhs) {
        case let (.absolute(a), .absolute(b)):
            return hypot(b.x - a.x, b.y - a.y)
        case let (.relative(a), .relative(b)):
            return hypot(b.x - a.x, b.y - a.y)
        default:
            return .greatestFiniteMagnitude
        }
    }

    private func makeReplayEvent(from event: RecordedInputEvent, targetDisplayID: CGDirectDisplayID) -> CGEvent? {
        switch event.type {
        case .keyDown, .keyUp:
            guard let keyCode = event.keyCode,
                  let replay = CGEvent(
                    keyboardEventSource: nil,
                    virtualKey: keyCode,
                    keyDown: event.type == .keyDown
                  ) else {
                return nil
            }
            replay.flags = event.flags
            return replay

        case .scrollWheel:
            let units: CGScrollEventUnit = event.scrollIsContinuous ? .pixel : .line
            guard let replay = CGEvent(
                scrollWheelEvent2Source: nil,
                units: units,
                wheelCount: 2,
                wheel1: event.scrollIsContinuous ? event.scrollPointDeltaY : event.scrollDeltaY,
                wheel2: event.scrollIsContinuous ? event.scrollPointDeltaX : event.scrollDeltaX,
                wheel3: 0
            ) else {
                return nil
            }
            replay.flags = event.flags
            if let point = resolvedReplayPoint(for: event.locationMode, targetDisplayID: targetDisplayID) {
                replay.location = point
            }
            return replay

        default:
            guard let point = resolvedReplayPoint(for: event.locationMode, targetDisplayID: targetDisplayID),
                  let replay = CGEvent(
                    mouseEventSource: nil,
                    mouseType: event.type,
                    mouseCursorPosition: point,
                    mouseButton: event.mouseButton
                  ) else {
                return nil
            }
            replay.flags = event.flags
            replay.setIntegerValueField(.mouseEventClickState, value: event.clickState)
            return replay
        }
    }

    private func resolvedReplayPoint(
        for locationMode: RecordedLocationMode?,
        targetDisplayID: CGDirectDisplayID
    ) -> CGPoint? {
        guard let locationMode else { return nil }

        switch locationMode {
        case .absolute(let point):
            return point
        case .relative(let normalized):
            let bounds = CGDisplayBounds(targetDisplayID)
            return PointerMath.denormalizedPoint(from: normalized, in: bounds, destinationYFlipped: true)
        }
    }

    private func eventMask(for types: Set<CGEventType>) -> CGEventMask {
        var mask: CGEventMask = 0
        for type in types {
            mask |= (CGEventMask(1) << type.rawValue)
        }
        return mask
    }

    private func shouldIgnoreWhileRecording() -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID
    }

    private func appendRecordedEvent(type: CGEventType, event: CGEvent) {
        guard isRecording else { return }
        guard recordableTypes.contains(type) else { return }
        guard !shouldIgnoreWhileRecording() else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let delay = recordedEvents.isEmpty ? 0 : max(0, now - lastEventTime)
        lastEventTime = now

        let flags = event.flags

        if type == .keyDown || type == .keyUp {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            recordedEvents.append(
                RecordedInputEvent(
                    delay: delay,
                    type: type,
                    flags: flags,
                    locationMode: nil,
                    keyCode: keyCode,
                    mouseButton: .left,
                    clickState: 0,
                    scrollDeltaY: 0,
                    scrollDeltaX: 0,
                    scrollPointDeltaY: 0,
                    scrollPointDeltaX: 0,
                    scrollIsContinuous: false
                )
            )
            return
        }

        let locationMode = classifyLocation(event.location)

        if type == .scrollWheel {
            let deltaY = Int32(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let deltaX = Int32(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            let pointDeltaY = Int32(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let pointDeltaX = Int32(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

            recordedEvents.append(
                RecordedInputEvent(
                    delay: delay,
                    type: type,
                    flags: flags,
                    locationMode: locationMode,
                    keyCode: nil,
                    mouseButton: .left,
                    clickState: 0,
                    scrollDeltaY: deltaY,
                    scrollDeltaX: deltaX,
                    scrollPointDeltaY: pointDeltaY,
                    scrollPointDeltaX: pointDeltaX,
                    scrollIsContinuous: isContinuous
                )
            )
            return
        }

        let buttonNumber = max(0, min(31, Int(event.getIntegerValueField(.mouseEventButtonNumber))))
        let mouseButton = CGMouseButton(rawValue: UInt32(buttonNumber)) ?? .left
        let clickState = event.getIntegerValueField(.mouseEventClickState)

        recordedEvents.append(
            RecordedInputEvent(
                delay: delay,
                type: type,
                flags: flags,
                locationMode: locationMode,
                keyCode: nil,
                mouseButton: mouseButton,
                clickState: clickState,
                scrollDeltaY: 0,
                scrollDeltaX: 0,
                scrollPointDeltaY: 0,
                scrollPointDeltaX: 0,
                scrollIsContinuous: false
            )
        )
    }

    private func classifyLocation(_ point: CGPoint) -> RecordedLocationMode {
        let hitDisplays = displayIDs(at: point)
        for displayID in hitDisplays where virtualDisplayIDs.contains(displayID) {
            let bounds = CGDisplayBounds(displayID)
            if let normalized = PointerMath.normalizedPoint(for: point, in: bounds, sourceYFlipped: true) {
                return .relative(normalized)
            }
        }
        return .absolute(point)
    }

    private func displayIDs(at point: CGPoint) -> [CGDirectDisplayID] {
        let maxDisplays: UInt32 = 16
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var count: UInt32 = 0
        let result = CGGetDisplaysWithPoint(point, maxDisplays, &ids, &count)
        guard result == .success, count > 0 else {
            return []
        }
        return Array(ids.prefix(Int(count)))
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let engine = Unmanaged<InputMacroEngine>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = engine.eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        engine.appendRecordedEvent(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }
}

private extension RecordedInputEvent {
    func withDelay(_ delay: TimeInterval) -> RecordedInputEvent {
        RecordedInputEvent(
            delay: delay,
            type: type,
            flags: flags,
            locationMode: locationMode,
            keyCode: keyCode,
            mouseButton: mouseButton,
            clickState: clickState,
            scrollDeltaY: scrollDeltaY,
            scrollDeltaX: scrollDeltaX,
            scrollPointDeltaY: scrollPointDeltaY,
            scrollPointDeltaX: scrollPointDeltaX,
            scrollIsContinuous: scrollIsContinuous
        )
    }
}
