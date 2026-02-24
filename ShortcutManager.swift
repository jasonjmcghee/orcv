import AppKit
import Foundation

enum ShortcutAction: String, CaseIterable {
    case toggleTeleport = "toggle_teleport"
    case newDisplay = "new_display"
    case removeDisplay = "remove_display"
    case focusNext = "focus_next"
    case focusPrevious = "focus_previous"
    case layoutFullWidth = "layout_full_width"
    case layout2x2 = "layout_2x2"
    case fullscreenSelected = "fullscreen_selected"

    var title: String {
        switch self {
        case .toggleTeleport: return "Toggle Teleport"
        case .newDisplay: return "New Display"
        case .removeDisplay: return "Remove Display"
        case .focusNext: return "Focus Next"
        case .focusPrevious: return "Focus Previous"
        case .layoutFullWidth: return "Layout Full Width"
        case .layout2x2: return "Layout 2x2"
        case .fullscreenSelected: return "Fullscreen Selected"
        }
    }

    var defaultShortcut: String {
        switch self {
        case .toggleTeleport: return "ctrl+alt+space"
        case .newDisplay: return "cmd+n"
        case .removeDisplay: return "cmd+w"
        case .focusNext: return "ctrl+alt+l"
        case .focusPrevious: return "ctrl+alt+h"
        case .layoutFullWidth: return "ctrl+alt+1"
        case .layout2x2: return "ctrl+alt+2"
        case .fullscreenSelected: return "ctrl+alt+f"
        }
    }

    var options: [String] {
        switch self {
        case .toggleTeleport:
            return ["ctrl+alt+space", "cmd+alt+space", "ctrl+alt+t"]
        case .newDisplay:
            return ["cmd+n", "ctrl+alt+n", "cmd+alt+n"]
        case .removeDisplay:
            return ["cmd+w", "ctrl+alt+backspace", "ctrl+alt+w"]
        case .focusNext:
            return ["ctrl+alt+l", "ctrl+alt+right", "cmd+alt+right"]
        case .focusPrevious:
            return ["ctrl+alt+h", "ctrl+alt+left", "cmd+alt+left"]
        case .layoutFullWidth:
            return ["ctrl+alt+1", "cmd+alt+1", "ctrl+alt+f"]
        case .layout2x2:
            return ["ctrl+alt+2", "cmd+alt+2", "ctrl+alt+g"]
        case .fullscreenSelected:
            return ["ctrl+alt+f", "cmd+shift+f", "ctrl+alt+enter"]
        }
    }
}

enum TileSizingMode: String, CaseIterable {
    case dynamic
    case fixed

    var title: String {
        switch self {
        case .dynamic: return "Dynamic"
        case .fixed: return "Fixed (Reasonable)"
        }
    }
}

struct ShortcutKeyChord {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let canonical: String
    let display: String
}

final class ShortcutManager {
    private let store: ShortcutStore
    private var bindings: [ShortcutAction: String]
    private var chords: [ShortcutAction: ShortcutKeyChord]
    private(set) var tileSizingMode: TileSizingMode

    var onDidChange: (() -> Void)?

    init(bundleIdentifier: String) {
        store = ShortcutStore(bundleIdentifier: bundleIdentifier)
        let loaded = store.load()
        var resolved: [ShortcutAction: String] = [:]
        for action in ShortcutAction.allCases {
            let loadedBinding = loaded.bindings[action]
            let candidate = Self.migrateLegacyDefault(for: action, loadedBinding: loadedBinding) ?? loadedBinding ?? action.defaultShortcut
            resolved[action] = candidate
        }
        bindings = resolved
        chords = ShortcutManager.compile(bindings: resolved)
        tileSizingMode = loaded.tileSizingMode ?? .dynamic
        store.save(bindings: bindings, tileSizingMode: tileSizingMode)
    }

    private static func migrateLegacyDefault(for action: ShortcutAction, loadedBinding: String?) -> String? {
        guard let loadedBinding else { return nil }
        switch action {
        case .newDisplay where loadedBinding == "ctrl+alt+n":
            return action.defaultShortcut
        case .removeDisplay where loadedBinding == "ctrl+alt+backspace":
            return action.defaultShortcut
        default:
            return nil
        }
    }

    func action(for event: NSEvent) -> ShortcutAction? {
        guard event.type == .keyDown, !event.isARepeat else { return nil }
        let eventMods = ShortcutManager.normalizeModifiers(event.modifierFlags)
        for action in ShortcutAction.allCases {
            guard let chord = chords[action] else { continue }
            if chord.keyCode == event.keyCode && chord.modifiers == eventMods {
                return action
            }
        }
        return nil
    }

    func bindingString(for action: ShortcutAction) -> String {
        bindings[action] ?? action.defaultShortcut
    }

    func displayLabel(for action: ShortcutAction) -> String {
        if let chord = chords[action] {
            return chord.display
        }
        return ShortcutManager.displayLabel(forShortcutString: action.defaultShortcut)
    }

    func updateBindings(_ updates: [ShortcutAction: String]) {
        var next = bindings
        for action in ShortcutAction.allCases {
            if let value = updates[action] {
                next[action] = value
            }
        }
        bindings = next
        chords = ShortcutManager.compile(bindings: next)
        store.save(bindings: bindings, tileSizingMode: tileSizingMode)
        onDidChange?()
    }

    func updateTileSizingMode(_ mode: TileSizingMode) {
        guard tileSizingMode != mode else { return }
        tileSizingMode = mode
        store.save(bindings: bindings, tileSizingMode: tileSizingMode)
        onDidChange?()
    }

    func shortcutsFilePath() -> String {
        store.filePath
    }

    static func displayLabel(forShortcutString shortcut: String) -> String {
        guard let parsed = parse(shortcut: shortcut) else { return shortcut }
        return parsed.display
    }

    private static func compile(bindings: [ShortcutAction: String]) -> [ShortcutAction: ShortcutKeyChord] {
        var map: [ShortcutAction: ShortcutKeyChord] = [:]
        for action in ShortcutAction.allCases {
            let source = bindings[action] ?? action.defaultShortcut
            if let chord = parse(shortcut: source) {
                map[action] = chord
            } else if let fallback = parse(shortcut: action.defaultShortcut) {
                map[action] = fallback
            }
        }
        return map
    }

    private static func parse(shortcut: String) -> ShortcutKeyChord? {
        let parts = shortcut
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var modifiers = NSEvent.ModifierFlags()
        var keyToken: String?

        for part in parts {
            switch part {
            case "ctrl", "control":
                modifiers.insert(.control)
            case "alt", "option":
                modifiers.insert(.option)
            case "cmd", "command":
                modifiers.insert(.command)
            case "shift":
                modifiers.insert(.shift)
            default:
                if keyToken != nil {
                    return nil
                }
                keyToken = part
            }
        }

        guard let keyToken, let key = keyCode(for: keyToken) else { return nil }
        let normalizedMods = normalizeModifiers(modifiers)
        let canonical = canonicalString(modifiers: normalizedMods, key: key.canonicalName)
        let display = displayString(modifiers: normalizedMods, key: key.displayName)

        return ShortcutKeyChord(
            keyCode: key.keyCode,
            modifiers: normalizedMods,
            canonical: canonical,
            display: display
        )
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

    private static func keyCode(for token: String) -> (keyCode: UInt16, canonicalName: String, displayName: String)? {
        if let mapped = keyMap[token] {
            return mapped
        }
        if token.count == 1, let mapped = keyMap[token] {
            return mapped
        }
        return nil
    }

    private static let keyMap: [String: (UInt16, String, String)] = [
        "space": (49, "space", "Space"),
        "enter": (36, "enter", "Enter"),
        "return": (36, "enter", "Enter"),
        "tab": (48, "tab", "Tab"),
        "esc": (53, "esc", "Esc"),
        "escape": (53, "esc", "Esc"),
        "backspace": (51, "backspace", "Backspace"),
        "delete": (51, "backspace", "Backspace"),
        "left": (123, "left", "Left"),
        "right": (124, "right", "Right"),
        "down": (125, "down", "Down"),
        "up": (126, "up", "Up"),
        "h": (4, "h", "H"),
        "j": (38, "j", "J"),
        "k": (40, "k", "K"),
        "l": (37, "l", "L"),
        "n": (45, "n", "N"),
        "w": (13, "w", "W"),
        "t": (17, "t", "T"),
        "f": (3, "f", "F"),
        "g": (5, "g", "G"),
        "1": (18, "1", "1"),
        "2": (19, "2", "2"),
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

    func load() -> (bindings: [ShortcutAction: String], tileSizingMode: TileSizingMode?) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return ([:], nil)
        }

        var currentSection = ""
        var map: [ShortcutAction: String] = [:]
        var tileSizingMode: TileSizingMode?

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("[") {
                currentSection = line
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            if currentSection == "[shortcuts]" {
                guard let action = ShortcutAction(rawValue: key) else { continue }
                map[action] = value
            } else if currentSection == "[layout]", key == "tile_sizing_mode" {
                tileSizingMode = TileSizingMode(rawValue: value)
            }
        }

        return (map, tileSizingMode)
    }

    func save(bindings: [ShortcutAction: String], tileSizingMode: TileSizingMode) {
        queue.async {
            var lines: [String] = []
            lines.append("# Workspace Grid shortcuts")
            lines.append("[shortcuts]")
            for action in ShortcutAction.allCases {
                let value = bindings[action] ?? action.defaultShortcut
                lines.append("\(action.rawValue) = \"\(value)\"")
            }
            lines.append("")
            lines.append("[layout]")
            lines.append("tile_sizing_mode = \"\(tileSizingMode.rawValue)\"")
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
