import AppKit
import Foundation

final class ShortcutSettingsWindowController: NSWindowController {
    private let shortcutManager: ShortcutManager
    private var valueLabels: [ShortcutAction: NSTextField] = [:]
    private var recordButtons: [ShortcutAction: NSButton] = [:]
    private var stagedBindings: [ShortcutAction: String] = [:]
    private var recordingAction: ShortcutAction?
    private var localMonitor: Any?
    private var doubleModifierState: [ShortcutModifier: TimeInterval] = [:]
    private var pendingDoubleKeyToken: String?
    private var pendingDoubleKeyTimestamp: TimeInterval = 0
    private var pendingSingleKeyCommitWorkItem: DispatchWorkItem?
    private let recordDoubleTapInterval: TimeInterval = 0.45

    init(shortcutManager: ShortcutManager) {
        self.shortcutManager = shortcutManager
        for action in ShortcutAction.allCases {
            stagedBindings[action] = shortcutManager.bindingString(for: action)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shortcuts"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        buildUI()
        installRecordingMonitorIfNeeded()
    }

    deinit {
        pendingSingleKeyCommitWorkItem?.cancel()
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        reloadStagedBindingsFromManager()
        stopRecording()
        refreshDisplayedBindings()
        super.showWindow(sender)
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

        let note = NSTextField(labelWithString: "Click Record, then press a shortcut. Double-tap a modifier for Cmd+Cmd / Shift+Shift style bindings.")
        note.textColor = .secondaryLabelColor
        note.font = NSFont.systemFont(ofSize: 12)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(note)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        for action in ShortcutAction.allCases {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10

            let title = NSTextField(labelWithString: action.title)
            title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            title.alignment = .right
            title.translatesAutoresizingMaskIntoConstraints = false
            title.widthAnchor.constraint(equalToConstant: 170).isActive = true

            let value = NSTextField(labelWithString: ShortcutManager.displayLabel(forShortcutString: stagedBindings[action] ?? action.defaultShortcut))
            value.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            value.textColor = .labelColor
            value.alignment = .left
            value.translatesAutoresizingMaskIntoConstraints = false
            value.widthAnchor.constraint(equalToConstant: 170).isActive = true
            valueLabels[action] = value

            let recordButton = NSButton(title: "Record", target: self, action: #selector(recordPressed(_:)))
            recordButton.bezelStyle = .rounded
            recordButton.tag = actionIndex(action)
            recordButtons[action] = recordButton

            let resetButton = NSButton(title: "Reset", target: self, action: #selector(resetPressed(_:)))
            resetButton.bezelStyle = .rounded
            resetButton.tag = actionIndex(action)

            row.addArrangedSubview(title)
            row.addArrangedSubview(value)
            row.addArrangedSubview(recordButton)
            row.addArrangedSubview(resetButton)
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
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            note.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),

            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 14),

            pathLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            pathLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            pathLabel.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 14),

            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            buttonRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])

        refreshRecordingUI()
        refreshDisplayedBindings()
    }

    @objc
    private func savePressed() {
        stopRecording()
        shortcutManager.updateBindings(stagedBindings)
        close()
    }

    @objc
    private func cancelPressed() {
        reloadStagedBindingsFromManager()
        stopRecording()
        refreshDisplayedBindings()
        close()
    }

    @objc
    private func recordPressed(_ sender: NSButton) {
        guard let action = actionForTag(sender.tag) else { return }
        if recordingAction == action {
            stopRecording()
            return
        }
        recordingAction = action
        doubleModifierState = [:]
        refreshRecordingUI()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
    }

    @objc
    private func resetPressed(_ sender: NSButton) {
        guard let action = actionForTag(sender.tag) else { return }
        stagedBindings[action] = action.defaultShortcut
        if recordingAction == action {
            stopRecording()
        }
        refreshDisplayedBindings()
    }

    private func installRecordingMonitorIfNeeded() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            guard self.window?.isVisible == true,
                  self.window?.isKeyWindow == true,
                  let action = self.recordingAction else {
                return event
            }

            switch event.type {
            case .keyDown:
                if event.keyCode == 53 {
                    self.stopRecording()
                    return nil
                }
                guard let canonical = ShortcutManager.shortcutString(forKeyDownEvent: event) else {
                    NSSound.beep()
                    return nil
                }

                let normalizedMods = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .intersection([.control, .option, .command, .shift])
                let isUnmodifiedSingle = normalizedMods.isEmpty && !canonical.contains("+")

                if isUnmodifiedSingle {
                    let now = event.timestamp
                    if self.pendingDoubleKeyToken == canonical,
                       self.pendingDoubleKeyTimestamp > 0,
                       now - self.pendingDoubleKeyTimestamp <= self.recordDoubleTapInterval {
                        self.pendingSingleKeyCommitWorkItem?.cancel()
                        self.pendingSingleKeyCommitWorkItem = nil
                        self.pendingDoubleKeyToken = nil
                        self.pendingDoubleKeyTimestamp = 0
                        self.stagedBindings[action] = "double_\(canonical)"
                        self.stopRecording()
                        self.refreshDisplayedBindings()
                        return nil
                    }

                    self.pendingSingleKeyCommitWorkItem?.cancel()
                    self.pendingSingleKeyCommitWorkItem = nil
                    self.pendingDoubleKeyToken = canonical
                    self.pendingDoubleKeyTimestamp = now
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        guard self.recordingAction == action else { return }
                        guard self.pendingDoubleKeyToken == canonical else { return }
                        self.stagedBindings[action] = canonical
                        self.stopRecording()
                        self.refreshDisplayedBindings()
                    }
                    self.pendingSingleKeyCommitWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.recordDoubleTapInterval, execute: work)
                    return nil
                }

                self.pendingSingleKeyCommitWorkItem?.cancel()
                self.pendingSingleKeyCommitWorkItem = nil
                self.pendingDoubleKeyToken = nil
                self.pendingDoubleKeyTimestamp = 0
                self.stagedBindings[action] = canonical
                self.stopRecording()
                self.refreshDisplayedBindings()
                return nil
            case .flagsChanged:
                if let token = ShortcutManager.captureDoubleModifier(from: event, state: &self.doubleModifierState) {
                    self.pendingSingleKeyCommitWorkItem?.cancel()
                    self.pendingSingleKeyCommitWorkItem = nil
                    self.pendingDoubleKeyToken = nil
                    self.pendingDoubleKeyTimestamp = 0
                    self.stagedBindings[action] = token
                    self.stopRecording()
                    self.refreshDisplayedBindings()
                }
                return nil
            default:
                return event
            }
        }
    }

    private func stopRecording() {
        pendingSingleKeyCommitWorkItem?.cancel()
        pendingSingleKeyCommitWorkItem = nil
        pendingDoubleKeyToken = nil
        pendingDoubleKeyTimestamp = 0
        recordingAction = nil
        doubleModifierState = [:]
        refreshRecordingUI()
    }

    private func refreshDisplayedBindings() {
        for action in ShortcutAction.allCases {
            let value = stagedBindings[action] ?? action.defaultShortcut
            valueLabels[action]?.stringValue = ShortcutManager.displayLabel(forShortcutString: value)
        }
    }

    private func refreshRecordingUI() {
        for action in ShortcutAction.allCases {
            guard let button = recordButtons[action] else { continue }
            let isRecording = (recordingAction == action)
            button.title = isRecording ? "Recording..." : "Record"
            button.state = isRecording ? .on : .off
        }
    }

    private func actionIndex(_ action: ShortcutAction) -> Int {
        ShortcutAction.allCases.firstIndex(of: action) ?? 0
    }

    private func actionForTag(_ tag: Int) -> ShortcutAction? {
        guard tag >= 0, tag < ShortcutAction.allCases.count else { return nil }
        return ShortcutAction.allCases[tag]
    }

    private func reloadStagedBindingsFromManager() {
        stagedBindings = [:]
        for action in ShortcutAction.allCases {
            stagedBindings[action] = shortcutManager.bindingString(for: action)
        }
    }
}
