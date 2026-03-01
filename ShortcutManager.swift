import AppKit
import Foundation

enum ShortcutAction: String, CaseIterable {
    case toggleTeleport = "toggle_teleport"
    case newDisplay = "new_display"
    case removeDisplay = "remove_display"
    case focusNext = "focus_next"
    case focusPrevious = "focus_previous"
    case fullscreenSelected = "fullscreen_selected"

    var title: String {
        switch self {
        case .toggleTeleport: return "Toggle Teleport"
        case .newDisplay: return "New Display"
        case .removeDisplay: return "Close Display"
        case .focusNext: return "Focus Next"
        case .focusPrevious: return "Focus Previous"
        case .fullscreenSelected: return "Fullscreen Selected"
        }
    }

    var defaultShortcut: String {
        switch self {
        case .toggleTeleport: return "double_cmd"
        case .newDisplay: return "cmd+n"
        case .removeDisplay: return "cmd+w"
        case .focusNext: return "ctrl+alt+right"
        case .focusPrevious: return "ctrl+alt+left"
        case .fullscreenSelected: return "cmd+shift+f"
        }
    }
}

enum ShortcutModifier: String, CaseIterable {
    case control = "ctrl"
    case option = "alt"
    case command = "cmd"
    case shift = "shift"

    var displayName: String {
        switch self {
        case .control: return "Ctrl"
        case .option: return "Alt"
        case .command: return "Cmd"
        case .shift: return "Shift"
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .control: return .control
        case .option: return .option
        case .command: return .command
        case .shift: return .shift
        }
    }

    var doubleToken: String {
        "double_\(rawValue)"
    }

    var doubleDisplay: String {
        "\(displayName)+\(displayName)"
    }
}

struct ShortcutKeyChord {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let canonical: String
    let display: String
}

private struct ShortcutDoubleKeyChord {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let canonical: String
    let display: String
}

private enum ShortcutBinding {
    case key(ShortcutKeyChord)
    case doubleModifier(ShortcutModifier)
    case doubleKey(ShortcutDoubleKeyChord)

    var canonical: String {
        switch self {
        case .key(let chord):
            return chord.canonical
        case .doubleModifier(let modifier):
            return modifier.doubleToken
        case .doubleKey(let chord):
            return chord.canonical
        }
    }

    var display: String {
        switch self {
        case .key(let chord):
            return chord.display
        case .doubleModifier(let modifier):
            return modifier.doubleDisplay
        case .doubleKey(let chord):
            return chord.display
        }
    }
}

private struct KeyTapIdentity: Hashable {
    let keyCode: UInt16
    let modifiersRawValue: UInt
}

final class ShortcutManager {
    private let store: ShortcutStore
    private var bindings: [ShortcutAction: String]
    private var compiled: [ShortcutAction: ShortcutBinding]
    private var lastTapByModifier: [ShortcutModifier: TimeInterval] = [:]
    private var lastTapByKey: [KeyTapIdentity: TimeInterval] = [:]
    private let doubleTapInterval: TimeInterval = 0.45

    var onDidChange: (() -> Void)?

    init(bundleIdentifier: String) {
        store = ShortcutStore(bundleIdentifier: bundleIdentifier)
        let loadedBindings = store.load()
        if Self.shouldResetToDefaults(loadedBindings) {
            let defaults = Self.defaultBindings()
            bindings = defaults
            compiled = Self.compile(bindings: defaults)
            store.save(bindings: defaults)
            return
        }

        var resolved: [ShortcutAction: String] = [:]
        for action in ShortcutAction.allCases {
            let value = loadedBindings[action] ?? action.defaultShortcut
            if let binding = Self.parse(bindingString: value) {
                resolved[action] = binding.canonical
            }
        }
        bindings = resolved
        compiled = Self.compile(bindings: resolved)
    }

    private static func shouldResetToDefaults(_ loaded: [ShortcutAction: String]) -> Bool {
        guard loaded.count == ShortcutAction.allCases.count else { return true }

        let legacyTeleportBindings: Set<String> = [
            "ctrl+alt+space",
            "cmd+alt+space",
            "ctrl+alt+t",
        ]

        for action in ShortcutAction.allCases {
            guard let raw = loaded[action] else { return true }
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return true }
            guard Self.parse(bindingString: normalized) != nil else { return true }

            if action == .toggleTeleport, legacyTeleportBindings.contains(normalized) {
                return true
            }
        }
        return false
    }

    private static func defaultBindings() -> [ShortcutAction: String] {
        var map: [ShortcutAction: String] = [:]
        for action in ShortcutAction.allCases {
            map[action] = action.defaultShortcut
        }
        return map
    }

    func action(for event: NSEvent) -> ShortcutAction? {
        switch event.type {
        case .keyDown:
            guard !event.isARepeat else { return nil }
            let modifiers = Self.normalizeModifiers(event.modifierFlags)
            var matchingDoubleKey: ShortcutDoubleKeyChord?
            for action in ShortcutAction.allCases {
                guard let binding = compiled[action] else { continue }
                switch binding {
                case .key(let chord):
                    if chord.keyCode == event.keyCode && chord.modifiers == modifiers {
                        return action
                    }
                case .doubleKey(let chord):
                    if chord.keyCode == event.keyCode && chord.modifiers == modifiers {
                        matchingDoubleKey = chord
                    }
                case .doubleModifier:
                    continue
                }
            }
            if let chord = matchingDoubleKey {
                let tapID = KeyTapIdentity(keyCode: chord.keyCode, modifiersRawValue: chord.modifiers.rawValue)
                let now = event.timestamp
                if let last = lastTapByKey[tapID], last > 0, now - last <= doubleTapInterval {
                    lastTapByKey[tapID] = 0
                    for action in ShortcutAction.allCases {
                        guard let binding = compiled[action] else { continue }
                        if case .doubleKey(let expected) = binding,
                           expected.keyCode == chord.keyCode,
                           expected.modifiers == chord.modifiers {
                            return action
                        }
                    }
                } else {
                    lastTapByKey[tapID] = now
                }
            }
        case .flagsChanged:
            guard let modifier = Self.modifierFromFlagsChanged(event) else { return nil }
            let isDown = CGEventSource.keyState(.combinedSessionState, key: event.keyCode)
            guard isDown else {
                // Ignore key-up transition; double-tap timing is based on key-down edges.
                return nil
            }
            let modifiers = Self.normalizeModifiers(event.modifierFlags)
            guard modifiers == modifier.flag else {
                lastTapByModifier[modifier] = 0
                return nil
            }

            let now = event.timestamp
            if let last = lastTapByModifier[modifier],
               last > 0,
               now - last <= doubleTapInterval {
                lastTapByModifier[modifier] = 0
                for action in ShortcutAction.allCases {
                    guard let binding = compiled[action] else { continue }
                    if case .doubleModifier(let expected) = binding, expected == modifier {
                        return action
                    }
                }
            } else {
                lastTapByModifier[modifier] = now
            }
        default:
            return nil
        }
        return nil
    }

    func bindingString(for action: ShortcutAction) -> String {
        bindings[action] ?? action.defaultShortcut
    }

    func displayLabel(for action: ShortcutAction) -> String {
        compiled[action]?.display ?? Self.displayLabel(forShortcutString: action.defaultShortcut)
    }

    func updateBindings(_ updates: [ShortcutAction: String]) {
        var next = bindings
        for action in ShortcutAction.allCases {
            guard let raw = updates[action], let parsed = Self.parse(bindingString: raw) else {
                continue
            }
            next[action] = parsed.canonical
        }
        bindings = next
        compiled = Self.compile(bindings: next)
        store.save(bindings: bindings)
        onDidChange?()
    }

    func shortcutsFilePath() -> String {
        store.filePath
    }

    static func displayLabel(forShortcutString shortcut: String) -> String {
        guard let binding = parse(bindingString: shortcut) else { return shortcut }
        return binding.display
    }

    static func shortcutString(forKeyDownEvent event: NSEvent) -> String? {
        guard event.type == .keyDown else { return nil }
        guard let keyToken = keyToken(for: event.keyCode) else { return nil }
        let modifiers = normalizeModifiers(event.modifierFlags)
        return canonicalString(modifiers: modifiers, key: keyToken)
    }

    static func displayLabel(forKeyDownEvent event: NSEvent) -> String? {
        guard event.type == .keyDown else { return nil }
        guard let keyDisplay = keyDisplayName(for: event.keyCode) else { return nil }
        let modifiers = normalizeModifiers(event.modifierFlags)
        return displayString(modifiers: modifiers, key: keyDisplay)
    }

    static func captureDoubleModifier(
        from event: NSEvent,
        state: inout [ShortcutModifier: TimeInterval],
        interval: TimeInterval = 0.45
    ) -> String? {
        guard event.type == .flagsChanged else { return nil }
        guard let modifier = modifierFromFlagsChanged(event) else { return nil }
        let isDown = CGEventSource.keyState(.combinedSessionState, key: event.keyCode)
        guard isDown else {
            // Ignore key-up transition; double-tap timing is based on key-down edges.
            return nil
        }
        let modifiers = normalizeModifiers(event.modifierFlags)
        guard modifiers == modifier.flag else {
            state[modifier] = 0
            return nil
        }

        let now = event.timestamp
        if let last = state[modifier], last > 0, now - last <= interval {
            state[modifier] = 0
            return modifier.doubleToken
        }

        state[modifier] = now
        return nil
    }

    private static func compile(bindings: [ShortcutAction: String]) -> [ShortcutAction: ShortcutBinding] {
        var map: [ShortcutAction: ShortcutBinding] = [:]
        for action in ShortcutAction.allCases {
            let source = bindings[action] ?? action.defaultShortcut
            if let parsed = parse(bindingString: source) {
                map[action] = parsed
            } else if let fallback = parse(bindingString: action.defaultShortcut) {
                map[action] = fallback
            }
        }
        return map
    }

    private static func parse(bindingString: String) -> ShortcutBinding? {
        let text = bindingString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !text.isEmpty else { return nil }

        if let specialBinding = parseSpecialDoubleBinding(text) {
            return specialBinding
        }

        let parts = text
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var modifiers = NSEvent.ModifierFlags()
        var keyToken: String?

        for part in parts {
            if let modifier = modifierTokenMap[part] {
                modifiers.insert(modifier.flag)
                continue
            }
            if keyToken != nil {
                return nil
            }
            keyToken = part
        }

        guard let keyToken,
              let normalizedKeyToken = normalizedKeyToken(for: keyToken),
              let keyCode = keyCode(for: normalizedKeyToken),
              let keyDisplay = keyDisplayForToken(normalizedKeyToken) else {
            return nil
        }

        let normalizedMods = normalizeModifiers(modifiers)
        let canonical = canonicalString(modifiers: normalizedMods, key: normalizedKeyToken)
        let display = displayString(modifiers: normalizedMods, key: keyDisplay)

        return .key(ShortcutKeyChord(keyCode: keyCode, modifiers: normalizedMods, canonical: canonical, display: display))
    }

    private static func parseSpecialDoubleBinding(_ text: String) -> ShortcutBinding? {
        if text.hasPrefix("double_") {
            let suffix = String(text.dropFirst("double_".count))
            if let modifier = modifierTokenMap[suffix] {
                return .doubleModifier(modifier)
            }
            if let keyToken = normalizedKeyToken(for: suffix),
               let keyCode = keyCode(for: keyToken),
               let display = keyDisplayForToken(keyToken) {
                return .doubleKey(
                    ShortcutDoubleKeyChord(
                        keyCode: keyCode,
                        modifiers: [],
                        canonical: "double_\(keyToken)",
                        display: "\(display)+\(display)"
                    )
                )
            }
            return nil
        }

        let parts = text
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2, parts[0] == parts[1] else { return nil }

        let token = parts[0]
        if let modifier = modifierTokenMap[token] {
            return .doubleModifier(modifier)
        }

        guard let keyToken = normalizedKeyToken(for: token),
              let keyCode = keyCode(for: keyToken),
              let display = keyDisplayForToken(keyToken) else {
            return nil
        }
        return .doubleKey(
            ShortcutDoubleKeyChord(
                keyCode: keyCode,
                modifiers: [],
                canonical: "double_\(keyToken)",
                display: "\(display)+\(display)"
            )
        )
    }

    private static func modifierFromFlagsChanged(_ event: NSEvent) -> ShortcutModifier? {
        switch event.keyCode {
        case 55, 54:
            return .command
        case 56, 60:
            return .shift
        case 58, 61:
            return .option
        case 59, 62:
            return .control
        default:
            return nil
        }
    }

    private static func normalizeModifiers(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifiers.intersection([.control, .option, .command, .shift])
    }

    private static func canonicalString(modifiers: NSEvent.ModifierFlags, key: String) -> String {
        var tokens: [String] = []
        if modifiers.contains(.control) { tokens.append("ctrl") }
        if modifiers.contains(.option) { tokens.append("alt") }
        if modifiers.contains(.command) { tokens.append("cmd") }
        if modifiers.contains(.shift) { tokens.append("shift") }
        tokens.append(key)
        return tokens.joined(separator: "+")
    }

    private static func displayString(modifiers: NSEvent.ModifierFlags, key: String) -> String {
        var tokens: [String] = []
        if modifiers.contains(.control) { tokens.append("Ctrl") }
        if modifiers.contains(.option) { tokens.append("Alt") }
        if modifiers.contains(.command) { tokens.append("Cmd") }
        if modifiers.contains(.shift) { tokens.append("Shift") }
        tokens.append(key)
        return tokens.joined(separator: "+")
    }

    private static func normalizedKeyToken(for token: String) -> String? {
        if keyTokenToCode[token] != nil {
            return token
        }
        return keyAliases[token]
    }

    private static func keyCode(for token: String) -> UInt16? {
        keyTokenToCode[token]
    }

    private static func keyToken(for keyCode: UInt16) -> String? {
        keyCodeToToken[keyCode]
    }

    private static func keyDisplayName(for keyCode: UInt16) -> String? {
        guard let token = keyCodeToToken[keyCode] else { return nil }
        return keyDisplayForToken(token)
    }

    private static func keyDisplayForToken(_ token: String) -> String? {
        if let mapped = keyTokenDisplay[token] {
            return mapped
        }
        if token.count == 1 {
            return token.uppercased()
        }
        return token.capitalized
    }

    private static let modifierTokenMap: [String: ShortcutModifier] = [
        "ctrl": .control,
        "control": .control,
        "alt": .option,
        "option": .option,
        "cmd": .command,
        "command": .command,
        "shift": .shift,
    ]

    // ANSI key codes used by our binding parser and recorder.
    private static let keyTokenToCode: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
        "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24,
        "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32,
        "[": 33, "i": 34, "p": 35, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48,
        "space": 49, "`": 50, "backspace": 51, "esc": 53, "left": 123, "right": 124,
        "down": 125, "up": 126,
    ]

    private static let keyAliases: [String: String] = [
        "delete": "backspace",
        "escape": "esc",
        "return": "enter",
    ]

    private static let keyCodeToToken: [UInt16: String] = {
        var map: [UInt16: String] = [:]
        for (token, code) in keyTokenToCode {
            map[code] = token
        }
        return map
    }()

    private static let keyTokenDisplay: [String: String] = [
        "enter": "Enter",
        "tab": "Tab",
        "space": "Space",
        "backspace": "Backspace",
        "esc": "Esc",
        "left": "Left",
        "right": "Right",
        "up": "Up",
        "down": "Down",
    ]
}

private final class ShortcutStore {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.pointworks.workspacegrid.shortcut-store")

    init(bundleIdentifier: String) {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let folder = appSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
        fileURL = folder.appendingPathComponent("shortcuts.toml", isDirectory: false)
    }

    var filePath: String {
        fileURL.path
    }

    func load() -> [ShortcutAction: String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return [:]
        }

        var currentSection = ""
        var map: [ShortcutAction: String] = [:]

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("[") {
                currentSection = line
                continue
            }

            guard currentSection == "[shortcuts]",
                  let eq = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            guard let action = ShortcutAction(rawValue: key) else { continue }
            map[action] = value
        }

        return map
    }

    func save(bindings: [ShortcutAction: String]) {
        queue.async {
            var lines: [String] = []
            lines.append("# Workspace Grid shortcuts")
            lines.append("[shortcuts]")
            for action in ShortcutAction.allCases {
                let value = bindings[action] ?? action.defaultShortcut
                lines.append("\(action.rawValue) = \"\(value)\"")
            }
            lines.append("")
            let content = lines.joined(separator: "\n")

            do {
                try FileManager.default.createDirectory(
                    at: self.fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try content.write(to: self.fileURL, atomically: true, encoding: .utf8)
            } catch {
                return
            }
        }
    }
}
