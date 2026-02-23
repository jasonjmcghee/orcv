import AppKit
import Foundation

final class ShortcutSettingsWindowController: NSWindowController {
    private let shortcutManager: ShortcutManager
    private var popups: [ShortcutAction: NSPopUpButton] = [:]
    private var tileSizingPopup: NSPopUpButton?

    init(shortcutManager: ShortcutManager) {
        self.shortcutManager = shortcutManager

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shortcuts"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        buildUI()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let root = NSView(frame: contentView.bounds)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(labelWithString: "Choose tiling-style shortcut mappings. Saved to shortcuts.toml.")
        note.textColor = .secondaryLabelColor
        note.font = NSFont.systemFont(ofSize: 12)
        note.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(note)

        root.addSubview(stack)

        let sizingRow = NSStackView()
        sizingRow.orientation = .horizontal
        sizingRow.alignment = .centerY
        sizingRow.spacing = 12

        let sizingLabel = NSTextField(labelWithString: "Tile Size Mode")
        sizingLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        sizingLabel.alignment = .right
        sizingLabel.translatesAutoresizingMaskIntoConstraints = false
        sizingLabel.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let sizingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sizingPopup.controlSize = .regular
        sizingPopup.translatesAutoresizingMaskIntoConstraints = false
        sizingPopup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        for mode in TileSizingMode.allCases {
            sizingPopup.addItem(withTitle: mode.title)
            sizingPopup.lastItem?.representedObject = mode.rawValue
        }
        if let idx = TileSizingMode.allCases.firstIndex(of: shortcutManager.tileSizingMode) {
            sizingPopup.selectItem(at: idx)
        }
        tileSizingPopup = sizingPopup

        sizingRow.addArrangedSubview(sizingLabel)
        sizingRow.addArrangedSubview(sizingPopup)
        stack.addArrangedSubview(sizingRow)

        for action in ShortcutAction.allCases {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12

            let label = NSTextField(labelWithString: action.title)
            label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            label.alignment = .right
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 140).isActive = true

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .regular
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 280).isActive = true

            let current = shortcutManager.bindingString(for: action)
            var options = action.options
            if !options.contains(current) {
                options.insert(current, at: 0)
            }
            for option in options {
                let title = ShortcutManager.displayLabel(forShortcutString: option)
                popup.addItem(withTitle: title)
                popup.lastItem?.representedObject = option
            }
            if let matchIndex = options.firstIndex(of: current) {
                popup.selectItem(at: matchIndex)
            }

            popups[action] = popup

            row.addArrangedSubview(label)
            row.addArrangedSubview(popup)
            stack.addArrangedSubview(row)
        }

        let pathLabel = NSTextField(labelWithString: shortcutManager.shortcutsFilePath())
        pathLabel.textColor = .tertiaryLabelColor
        pathLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pathLabel)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancelButton.bezelStyle = .rounded

        let saveButton = NSButton(title: "Save", target: self, action: #selector(savePressed))
        saveButton.bezelStyle = .rounded

        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(saveButton)
        root.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            note.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),

            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 14),

            pathLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            pathLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            pathLabel.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 14),

            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            buttonRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
    }

    @objc
    private func savePressed() {
        var updates: [ShortcutAction: String] = [:]
        for action in ShortcutAction.allCases {
            guard let popup = popups[action],
                  let represented = popup.selectedItem?.representedObject as? String else {
                continue
            }
            updates[action] = represented
        }
        if let tileSizingPopup,
           let represented = tileSizingPopup.selectedItem?.representedObject as? String,
           let mode = TileSizingMode(rawValue: represented) {
            shortcutManager.updateTileSizingMode(mode)
        }
        shortcutManager.updateBindings(updates)
        close()
    }

    @objc
    private func cancelPressed() {
        close()
    }
}
