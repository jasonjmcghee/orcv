import AppKit
import Foundation

final class ArrangeSettingsWindowController: NSWindowController {
    private let onSave: (CGFloat) -> Void
    private let currentPadding: () -> CGFloat
    private let paddingField = NSTextField()

    init(currentPadding: @escaping () -> CGFloat, onSave: @escaping (CGFloat) -> Void) {
        self.currentPadding = currentPadding
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 130),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Arrange Settings"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        paddingField.doubleValue = Double(currentPadding())
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

        let label = NSTextField(labelWithString: "Padding between tiles:")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        paddingField.translatesAutoresizingMaskIntoConstraints = false
        paddingField.doubleValue = Double(currentPadding())
        paddingField.alignment = .right
        paddingField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        formatter.maximum = 1000
        formatter.maximumFractionDigits = 1
        paddingField.formatter = formatter

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = NSButton(title: "Save", target: self, action: #selector(savePressed))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(label)
        root.addSubview(paddingField)
        root.addSubview(cancelButton)
        root.addSubview(saveButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),

            paddingField.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            paddingField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            paddingField.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            paddingField.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),

            saveButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])
    }

    @objc
    private func savePressed() {
        let value = CGFloat(paddingField.doubleValue)
        onSave(value)
        close()
    }

    @objc
    private func cancelPressed() {
        close()
    }
}
