import AppKit
import Foundation

final class LimitFPSSettingsWindowController: NSWindowController {
    private let currentLimitFPS: () -> Double
    private let currentUnlockIfInteracting: () -> Bool
    private let currentUnlockIfLargerThanPercent: () -> Bool
    private let currentUnlockThresholdPercent: () -> Double
    private let onSave: (_ limitFPS: Double, _ unlockIfInteracting: Bool, _ unlockIfLargerThanPercent: Bool, _ unlockThresholdPercent: Double) -> Void

    private let limitFPSField = NSTextField()
    private let unlockIfInteractingToggle = NSButton(checkboxWithTitle: "Unlock FPS if interacting", target: nil, action: nil)
    private let unlockIfLargerToggle = NSButton(checkboxWithTitle: "Unlock FPS if larger than X%", target: nil, action: nil)
    private let unlockThresholdField = NSTextField()

    init(
        currentLimitFPS: @escaping () -> Double,
        currentUnlockIfInteracting: @escaping () -> Bool,
        currentUnlockIfLargerThanPercent: @escaping () -> Bool,
        currentUnlockThresholdPercent: @escaping () -> Double,
        onSave: @escaping (_ limitFPS: Double, _ unlockIfInteracting: Bool, _ unlockIfLargerThanPercent: Bool, _ unlockThresholdPercent: Double) -> Void
    ) {
        self.currentLimitFPS = currentLimitFPS
        self.currentUnlockIfInteracting = currentUnlockIfInteracting
        self.currentUnlockIfLargerThanPercent = currentUnlockIfLargerThanPercent
        self.currentUnlockThresholdPercent = currentUnlockThresholdPercent
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 215),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Limit FPS Settings"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        limitFPSField.doubleValue = currentLimitFPS()
        unlockIfInteractingToggle.state = currentUnlockIfInteracting() ? .on : .off
        unlockIfLargerToggle.state = currentUnlockIfLargerThanPercent() ? .on : .off
        unlockThresholdField.doubleValue = currentUnlockThresholdPercent()
        refreshEnabledState()
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

        let limitLabel = NSTextField(labelWithString: "Limit capture FPS:")
        limitLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        limitLabel.translatesAutoresizingMaskIntoConstraints = false

        limitFPSField.translatesAutoresizingMaskIntoConstraints = false
        limitFPSField.alignment = .right
        limitFPSField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let fpsFormatter = NumberFormatter()
        fpsFormatter.numberStyle = .decimal
        fpsFormatter.minimum = 1
        fpsFormatter.maximum = 120
        fpsFormatter.maximumFractionDigits = 1
        limitFPSField.formatter = fpsFormatter

        unlockIfInteractingToggle.translatesAutoresizingMaskIntoConstraints = false

        unlockIfLargerToggle.translatesAutoresizingMaskIntoConstraints = false
        unlockIfLargerToggle.target = self
        unlockIfLargerToggle.action = #selector(unlockIfLargerToggleChanged)

        let thresholdLabel = NSTextField(labelWithString: "Threshold (% of viewport):")
        thresholdLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        thresholdLabel.translatesAutoresizingMaskIntoConstraints = false

        unlockThresholdField.translatesAutoresizingMaskIntoConstraints = false
        unlockThresholdField.alignment = .right
        unlockThresholdField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let thresholdFormatter = NumberFormatter()
        thresholdFormatter.numberStyle = .decimal
        thresholdFormatter.minimum = 1
        thresholdFormatter.maximum = 100
        thresholdFormatter.maximumFractionDigits = 1
        unlockThresholdField.formatter = thresholdFormatter

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = NSButton(title: "Save", target: self, action: #selector(savePressed))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(limitLabel)
        root.addSubview(limitFPSField)
        root.addSubview(unlockIfInteractingToggle)
        root.addSubview(unlockIfLargerToggle)
        root.addSubview(thresholdLabel)
        root.addSubview(unlockThresholdField)
        root.addSubview(cancelButton)
        root.addSubview(saveButton)

        NSLayoutConstraint.activate([
            limitLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            limitLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),

            limitFPSField.leadingAnchor.constraint(equalTo: limitLabel.trailingAnchor, constant: 10),
            limitFPSField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            limitFPSField.centerYAnchor.constraint(equalTo: limitLabel.centerYAnchor),
            limitFPSField.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),

            unlockIfInteractingToggle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            unlockIfInteractingToggle.topAnchor.constraint(equalTo: limitLabel.bottomAnchor, constant: 16),

            unlockIfLargerToggle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            unlockIfLargerToggle.topAnchor.constraint(equalTo: unlockIfInteractingToggle.bottomAnchor, constant: 10),

            thresholdLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            thresholdLabel.topAnchor.constraint(equalTo: unlockIfLargerToggle.bottomAnchor, constant: 10),

            unlockThresholdField.leadingAnchor.constraint(equalTo: thresholdLabel.trailingAnchor, constant: 10),
            unlockThresholdField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            unlockThresholdField.centerYAnchor.constraint(equalTo: thresholdLabel.centerYAnchor),
            unlockThresholdField.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),

            saveButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])
    }

    @objc
    private func savePressed() {
        let limitFPS = min(120.0, max(1.0, limitFPSField.doubleValue))
        let threshold = min(100.0, max(1.0, unlockThresholdField.doubleValue))
        onSave(
            limitFPS,
            unlockIfInteractingToggle.state == .on,
            unlockIfLargerToggle.state == .on,
            threshold
        )
        close()
    }

    @objc
    private func cancelPressed() {
        close()
    }

    @objc
    private func unlockIfLargerToggleChanged() {
        refreshEnabledState()
    }

    private func refreshEnabledState() {
        unlockThresholdField.isEnabled = unlockIfLargerToggle.state == .on
    }
}
