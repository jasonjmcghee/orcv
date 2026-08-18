import AppKit
import Foundation

final class DisplayResolutionSettingsWindowController: NSWindowController {
    private struct Preset {
        let title: String
        let resolution: DisplayResolution?
    }

    /// nil resolution = mirror the main display. The last entry is the custom escape hatch.
    private static let presets: [Preset] = [
        Preset(title: "Match Main Display", resolution: nil),
        Preset(title: "1920 \u{00D7} 1080 (16:9)", resolution: DisplayResolution(width: 1920, height: 1080, hiDPI: true)),
        Preset(title: "1680 \u{00D7} 1050 (16:10)", resolution: DisplayResolution(width: 1680, height: 1050, hiDPI: true)),
        Preset(title: "1600 \u{00D7} 1200 (4:3)", resolution: DisplayResolution(width: 1600, height: 1200, hiDPI: true)),
        Preset(title: "1440 \u{00D7} 1080 (4:3)", resolution: DisplayResolution(width: 1440, height: 1080, hiDPI: true)),
        Preset(title: "1280 \u{00D7} 1024 (5:4)", resolution: DisplayResolution(width: 1280, height: 1024, hiDPI: true)),
        Preset(title: "Custom\u{2026}", resolution: nil),
    ]

    private static var customPresetIndex: Int { presets.count - 1 }

    private let onSave: (DisplayResolution?) -> Void
    private let currentResolution: () -> DisplayResolution?
    private let presetPopUp = NSPopUpButton()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let hiDPICheckbox = NSButton(checkboxWithTitle: "HiDPI (Retina)", target: nil, action: nil)

    init(
        currentResolution: @escaping () -> DisplayResolution?,
        onSave: @escaping (DisplayResolution?) -> Void
    ) {
        self.currentResolution = currentResolution
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "New Display Resolution"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        loadCurrentSelection()
        super.showWindow(sender)
        window?.center()
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

        let presetLabel = NSTextField(labelWithString: "Resolution:")
        presetLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        presetLabel.translatesAutoresizingMaskIntoConstraints = false

        presetPopUp.translatesAutoresizingMaskIntoConstraints = false
        presetPopUp.addItems(withTitles: Self.presets.map(\.title))
        presetPopUp.target = self
        presetPopUp.action = #selector(presetChanged)

        let sizeLabel = NSTextField(labelWithString: "Custom size:")
        sizeLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false

        let timesLabel = NSTextField(labelWithString: "\u{00D7}")
        timesLabel.translatesAutoresizingMaskIntoConstraints = false

        for field in [widthField, heightField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.alignment = .right
            field.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            let formatter = NumberFormatter()
            formatter.numberStyle = .none
            formatter.minimum = 320
            formatter.maximum = 8192
            field.formatter = formatter
        }

        hiDPICheckbox.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(labelWithString: "Applies to displays created from now on.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = NSButton(title: "Save", target: self, action: #selector(savePressed))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        for subview in [presetLabel, presetPopUp, sizeLabel, widthField, timesLabel, heightField, hiDPICheckbox, note, cancelButton, saveButton] {
            root.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            presetLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            presetLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),

            presetPopUp.leadingAnchor.constraint(equalTo: presetLabel.trailingAnchor, constant: 10),
            presetPopUp.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            presetPopUp.centerYAnchor.constraint(equalTo: presetLabel.centerYAnchor),

            sizeLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            sizeLabel.topAnchor.constraint(equalTo: presetPopUp.bottomAnchor, constant: 16),

            widthField.leadingAnchor.constraint(equalTo: sizeLabel.trailingAnchor, constant: 10),
            widthField.centerYAnchor.constraint(equalTo: sizeLabel.centerYAnchor),
            widthField.widthAnchor.constraint(equalToConstant: 70),

            timesLabel.leadingAnchor.constraint(equalTo: widthField.trailingAnchor, constant: 6),
            timesLabel.centerYAnchor.constraint(equalTo: sizeLabel.centerYAnchor),

            heightField.leadingAnchor.constraint(equalTo: timesLabel.trailingAnchor, constant: 6),
            heightField.centerYAnchor.constraint(equalTo: sizeLabel.centerYAnchor),
            heightField.widthAnchor.constraint(equalToConstant: 70),

            hiDPICheckbox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            hiDPICheckbox.topAnchor.constraint(equalTo: sizeLabel.bottomAnchor, constant: 16),

            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            note.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            note.topAnchor.constraint(equalTo: hiDPICheckbox.bottomAnchor, constant: 12),

            saveButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])
    }

    private func loadCurrentSelection() {
        let current = currentResolution()
        let matchedIndex = Self.presets.firstIndex { preset in
            preset.resolution == current
        }

        if let current {
            widthField.integerValue = current.width
            heightField.integerValue = current.height
            hiDPICheckbox.state = current.hiDPI ? .on : .off
            presetPopUp.selectItem(at: matchedIndex ?? Self.customPresetIndex)
        } else {
            widthField.integerValue = 1600
            heightField.integerValue = 1200
            hiDPICheckbox.state = .on
            presetPopUp.selectItem(at: 0)
        }
        updateCustomFieldsEnabled()
    }

    private var isCustomSelected: Bool {
        presetPopUp.indexOfSelectedItem == Self.customPresetIndex
    }

    private func updateCustomFieldsEnabled() {
        let enabled = isCustomSelected
        widthField.isEnabled = enabled
        heightField.isEnabled = enabled
        hiDPICheckbox.isEnabled = presetPopUp.indexOfSelectedItem != 0
    }

    @objc
    private func presetChanged() {
        let index = presetPopUp.indexOfSelectedItem
        if let resolution = Self.presets[index].resolution {
            widthField.integerValue = resolution.width
            heightField.integerValue = resolution.height
            hiDPICheckbox.state = resolution.hiDPI ? .on : .off
        }
        updateCustomFieldsEnabled()
    }

    @objc
    private func savePressed() {
        let index = presetPopUp.indexOfSelectedItem
        let resolution: DisplayResolution?
        if index == 0 {
            resolution = nil
        } else if isCustomSelected {
            resolution = DisplayResolution(
                width: widthField.integerValue,
                height: heightField.integerValue,
                hiDPI: hiDPICheckbox.state == .on
            )
        } else {
            var preset = Self.presets[index].resolution
            preset?.hiDPI = hiDPICheckbox.state == .on
            resolution = preset
        }
        onSave(resolution)
        close()
    }

    @objc
    private func cancelPressed() {
        close()
    }
}
