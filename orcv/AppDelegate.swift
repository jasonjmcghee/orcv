import AppKit
import CoreGraphics
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let mainWindowAutosaveName = "orcvMainWindowFrame"

    private var window: NSWindow?
    private var rootViewController: WorkspaceRootViewController?
    private var shortcutManager: ShortcutManager?
    private var shortcutsWindowController: ShortcutSettingsWindowController?
    private var aboutWindowController: OrcvAboutWindowController?
    private var permissionsWindowController: PermissionGateWindowController?
    private var alwaysOnTopMenuItem: NSMenuItem?
    private var showDisplayIDsMenuItem: NSMenuItem?
    private var centerTileOnJumpMenuItem: NSMenuItem?
    private var preserveSizeOnSlotJumpMenuItem: NSMenuItem?
    private var restoreWindowFrameOnSavepointRecallMenuItem: NSMenuItem?
    private var swapResizeBehaviorMenuItem: NSMenuItem?
    private var terminateInProgress = false
    private var didShowMainWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification

        installMainMenu()
        evaluateLaunchPermissions()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        _ = notification
        guard rootViewController == nil else { return }
        evaluateLaunchPermissions()
    }

    private func startMainApplication(hasScreenCaptureAccess: Bool) {
        guard window == nil, rootViewController == nil else { return }
        let displayManager = VirtualDisplayManager()
        let workspaceStore = WorkspaceStore()
        let pointerRouter = PointerRouter()
        let bundleID = Bundle.main.bundleIdentifier ?? "today.jason.orcv"
        let shortcutManager = ShortcutManager(bundleIdentifier: bundleID)
        let stateStore = WorkspaceStateStore(bundleIdentifier: bundleID)
        self.shortcutManager = shortcutManager

        let root = WorkspaceRootViewController(
            displayManager: displayManager,
            workspaceStore: workspaceStore,
            pointerRouter: pointerRouter,
            shortcutManager: shortcutManager,
            stateStore: stateStore,
            hasScreenCaptureAccess: hasScreenCaptureAccess
        )

        let window = NSWindow(
            contentRect: NSRect(x: 140, y: 120, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "orcv"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .windowBackgroundColor
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .none
        var behavior = window.collectionBehavior
        behavior.remove([.fullScreenPrimary, .fullScreenAllowsTiling])
        window.collectionBehavior = behavior
        window.delegate = self
        window.contentViewController = root
        applyChromelessWindowStyle(window)

        window.setFrameAutosaveName(Self.mainWindowAutosaveName)
        _ = window.setFrameUsingName(Self.mainWindowAutosaveName, force: false)

        self.window = window
        self.rootViewController = root
        root.onInitialBootstrapComplete = { [weak self] in
            self?.showMainWindowWhenReady()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        rootViewController?.flushStateNow()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        guard !terminateInProgress else { return .terminateNow }
        guard let rootViewController else { return .terminateNow }

        terminateInProgress = true
        rootViewController.beginShutdown {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        _ = sender
        return true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(
            title: "About orcv",
            action: #selector(showAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let shortcutsItem = NSMenuItem(
            title: "Shortcuts…",
            action: #selector(showShortcutsSettings(_:)),
            keyEquivalent: ","
        )
        shortcutsItem.target = self
        appMenu.addItem(shortcutsItem)
        appMenu.addItem(.separator())

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "orcv"
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)

        let fileMenu = NSMenu(title: "File")
        let newDisplayItem = NSMenuItem(
            title: "New Display",
            action: #selector(fileNewDisplay(_:)),
            keyEquivalent: "n"
        )
        newDisplayItem.keyEquivalentModifierMask = [.command]
        newDisplayItem.target = self
        fileMenu.addItem(newDisplayItem)

        let closeDisplayItem = NSMenuItem(
            title: "Close Display",
            action: #selector(fileCloseDisplay(_:)),
            keyEquivalent: "w"
        )
        closeDisplayItem.keyEquivalentModifierMask = [.command]
        closeDisplayItem.target = self
        fileMenu.addItem(closeDisplayItem)
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(
            title: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        undoItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(
            title: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "Z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenuItem.submenu = editMenu

        let navigateMenuItem = NSMenuItem()
        mainMenu.addItem(navigateMenuItem)

        let navigateMenu = NSMenu(title: "Navigate")
        let jumpNextDisplayItem = NSMenuItem(
            title: "Jump Next Display",
            action: #selector(navigateJumpNextDisplay(_:)),
            keyEquivalent: ""
        )
        jumpNextDisplayItem.target = self
        navigateMenu.addItem(jumpNextDisplayItem)

        let jumpPreviousDisplayItem = NSMenuItem(
            title: "Jump Previous Display",
            action: #selector(navigateJumpPreviousDisplay(_:)),
            keyEquivalent: ""
        )
        jumpPreviousDisplayItem.target = self
        navigateMenu.addItem(jumpPreviousDisplayItem)
        navigateMenu.addItem(.separator())

        let deselectTileItem = NSMenuItem(
            title: "Deselect Tile",
            action: #selector(navigateDeselectTile(_:)),
            keyEquivalent: ""
        )
        deselectTileItem.target = self
        navigateMenu.addItem(deselectTileItem)
        navigateMenuItem.submenu = navigateMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)

        let viewMenu = NSMenu(title: "View")
        let alwaysOnTopItem = NSMenuItem(
            title: "Always on Top",
            action: #selector(toggleAlwaysOnTop(_:)),
            keyEquivalent: "t"
        )
        alwaysOnTopItem.keyEquivalentModifierMask = [.command, .option]
        alwaysOnTopItem.target = self
        alwaysOnTopItem.state = .off
        alwaysOnTopMenuItem = alwaysOnTopItem
        viewMenu.addItem(alwaysOnTopItem)

        let showDisplayIDsItem = NSMenuItem(
            title: "Show Display Indexes",
            action: #selector(toggleShowDisplayIDs(_:)),
            keyEquivalent: ""
        )
        showDisplayIDsItem.target = self
        showDisplayIDsItem.state = .off
        showDisplayIDsMenuItem = showDisplayIDsItem

        let centerTileOnJumpItem = NSMenuItem(
            title: "Center Tile on Jump",
            action: #selector(toggleCenterTileOnJump(_:)),
            keyEquivalent: ""
        )
        centerTileOnJumpItem.target = self
        centerTileOnJumpItem.state = .off
        centerTileOnJumpMenuItem = centerTileOnJumpItem
        viewMenu.addItem(centerTileOnJumpItem)

        let preserveSizeOnSlotJumpItem = NSMenuItem(
            title: "Preserve View on Jump",
            action: #selector(togglePreserveSizeOnSlotJump(_:)),
            keyEquivalent: ""
        )
        preserveSizeOnSlotJumpItem.target = self
        preserveSizeOnSlotJumpItem.state = .on
        preserveSizeOnSlotJumpMenuItem = preserveSizeOnSlotJumpItem
        viewMenu.addItem(preserveSizeOnSlotJumpItem)

        let restoreWindowFrameOnSavepointRecallItem = NSMenuItem(
            title: "Preserve Window Frame with Savepoint",
            action: #selector(toggleRestoreWindowFrameOnSavepointRecall(_:)),
            keyEquivalent: ""
        )
        restoreWindowFrameOnSavepointRecallItem.target = self
        restoreWindowFrameOnSavepointRecallItem.state = .on
        restoreWindowFrameOnSavepointRecallMenuItem = restoreWindowFrameOnSavepointRecallItem
        viewMenu.addItem(restoreWindowFrameOnSavepointRecallItem)

        let swapResizeBehaviorItem = NSMenuItem(
            title: "Swap Resize Behavior",
            action: #selector(toggleSwapResizeBehavior(_:)),
            keyEquivalent: ""
        )
        swapResizeBehaviorItem.target = self
        swapResizeBehaviorItem.state = .off
        swapResizeBehaviorMenuItem = swapResizeBehaviorItem
        viewMenu.addItem(swapResizeBehaviorItem)

        viewMenu.addItem(.separator())

        let resetZoomItem = NSMenuItem(
            title: "Reset Zoom",
            action: #selector(resetCanvasZoom(_:)),
            keyEquivalent: ""
        )
        resetZoomItem.target = self
        viewMenu.addItem(resetZoomItem)

        let jumpToOriginItem = NSMenuItem(
            title: "Jump to Origin",
            action: #selector(jumpToCanvasOrigin(_:)),
            keyEquivalent: "o"
        )
        jumpToOriginItem.keyEquivalentModifierMask = [.command, .option]
        jumpToOriginItem.target = self
        viewMenu.addItem(jumpToOriginItem)
        viewMenuItem.submenu = viewMenu

        let developerMenuItem = NSMenuItem()
        mainMenu.addItem(developerMenuItem)

        let developerMenu = NSMenu(title: "Developer")
        developerMenu.addItem(showDisplayIDsItem)
        developerMenuItem.submenu = developerMenu

        NSApp.mainMenu = mainMenu
    }

    private struct LaunchPermissionState {
        let hasAccessibility: Bool
        let hasScreenCapture: Bool

        var hasAllRequired: Bool {
            hasAccessibility && hasScreenCapture
        }
    }

    private func currentPermissionState() -> LaunchPermissionState {
        LaunchPermissionState(
            hasAccessibility: AccessibilityAuthorization.hasAccess(),
            hasScreenCapture: ScreenCaptureAuthorization.hasAccess()
        )
    }

    private func evaluateLaunchPermissions() {
        let state = currentPermissionState()
        if state.hasAllRequired {
            permissionsWindowController?.close()
            permissionsWindowController = nil
            startMainApplication(hasScreenCaptureAccess: state.hasScreenCapture)
            return
        }
        presentPermissionsWindow(state: state)
    }

    private func presentPermissionsWindow(state: LaunchPermissionState) {
        if permissionsWindowController == nil {
            permissionsWindowController = PermissionGateWindowController(
                onRequestAccessibility: { [weak self] in
                    self?.handleRequestAccessibilityPermission()
                },
                onOpenAccessibilitySettings: { [weak self] in
                    self?.handleOpenAccessibilitySettings()
                },
                onRequestScreenCapture: { [weak self] in
                    self?.handleRequestScreenCapturePermission()
                },
                onOpenScreenCaptureSettings: { [weak self] in
                    self?.handleOpenScreenCaptureSettings()
                },
                onRefresh: { [weak self] in
                    self?.evaluateLaunchPermissions()
                },
                onContinue: { [weak self] in
                    self?.handleContinueFromPermissionsWindow()
                }
            )
        }

        permissionsWindowController?.updateStatus(
            hasAccessibility: state.hasAccessibility,
            hasScreenCapture: state.hasScreenCapture
        )
        permissionsWindowController?.showWindow(nil)
        permissionsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleRequestAccessibilityPermission() {
        _ = AccessibilityAuthorization.requestIfNeeded()
        evaluateLaunchPermissions()
    }

    private func handleOpenAccessibilitySettings() {
        AccessibilityAuthorization.openSystemSettings()
        evaluateLaunchPermissions()
    }

    private func handleRequestScreenCapturePermission() {
        _ = ScreenCaptureAuthorization.requestIfNeeded()
        evaluateLaunchPermissions()
    }

    private func handleOpenScreenCaptureSettings() {
        ScreenCaptureAuthorization.openSystemSettings()
        evaluateLaunchPermissions()
    }

    private func handleContinueFromPermissionsWindow() {
        let state = currentPermissionState()
        guard state.hasAllRequired else {
            permissionsWindowController?.updateStatus(
                hasAccessibility: state.hasAccessibility,
                hasScreenCapture: state.hasScreenCapture
            )
            NSSound.beep()
            return
        }
        evaluateLaunchPermissions()
    }

    @objc
    private func showShortcutsSettings(_ sender: Any?) {
        _ = sender
        guard let shortcutManager else { return }
        if shortcutsWindowController == nil {
            shortcutsWindowController = ShortcutSettingsWindowController(shortcutManager: shortcutManager)
        }
        shortcutsWindowController?.showWindow(nil)
        shortcutsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func showAboutPanel(_ sender: Any?) {
        _ = sender
        if aboutWindowController == nil {
            aboutWindowController = OrcvAboutWindowController()
        }
        aboutWindowController?.showWindow(nil)
        aboutWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func fileNewDisplay(_ sender: Any?) {
        _ = sender
        rootViewController?.menuNewDisplay()
    }

    @objc
    private func fileCloseDisplay(_ sender: Any?) {
        _ = sender
        rootViewController?.menuRemoveFocusedDisplay()
    }

    @objc
    private func navigateJumpNextDisplay(_ sender: Any?) {
        _ = sender
        rootViewController?.menuJumpNextDisplay()
    }

    @objc
    private func navigateJumpPreviousDisplay(_ sender: Any?) {
        _ = sender
        rootViewController?.menuJumpPreviousDisplay()
    }

    @objc
    private func navigateDeselectTile(_ sender: Any?) {
        _ = sender
        rootViewController?.menuDeselectTile()
    }

    @objc
    private func resetCanvasZoom(_ sender: Any?) {
        _ = sender
        rootViewController?.menuResetCanvasZoom()
    }

    @objc
    private func jumpToCanvasOrigin(_ sender: Any?) {
        _ = sender
        rootViewController?.menuJumpToCanvasOrigin()
    }

    @objc
    private func toggleAlwaysOnTop(_ sender: Any?) {
        _ = sender
        rootViewController?.menuToggleAlwaysOnTop()
        alwaysOnTopMenuItem?.state = rootViewController?.menuAlwaysOnTopEnabled() == true ? .on : .off
    }

    @objc
    private func toggleShowDisplayIDs(_ sender: Any?) {
        _ = sender
        rootViewController?.menuToggleShowDisplayIDs()
        showDisplayIDsMenuItem?.state = rootViewController?.menuShowDisplayIDsEnabled() == true ? .on : .off
    }

    @objc
    private func toggleCenterTileOnJump(_ sender: Any?) {
        _ = sender
        rootViewController?.menuToggleCenterTileOnJump()
        centerTileOnJumpMenuItem?.state = rootViewController?.menuCenterTileOnJumpEnabled() == true ? .on : .off
    }

    @objc
    private func togglePreserveSizeOnSlotJump(_ sender: Any?) {
        _ = sender
        rootViewController?.menuTogglePreserveSizeOnSlotJump()
        preserveSizeOnSlotJumpMenuItem?.state = rootViewController?.menuPreserveSizeOnSlotJumpEnabled() == true ? .on : .off
    }

    @objc
    private func toggleRestoreWindowFrameOnSavepointRecall(_ sender: Any?) {
        _ = sender
        rootViewController?.menuToggleRestoreWindowFrameOnSavepointRecall()
        restoreWindowFrameOnSavepointRecallMenuItem?.state = rootViewController?.menuRestoreWindowFrameOnSavepointRecallEnabled() == true ? .on : .off
    }

    @objc
    private func toggleSwapResizeBehavior(_ sender: Any?) {
        _ = sender
        rootViewController?.menuToggleSwapResizeBehavior()
        swapResizeBehaviorMenuItem?.state = rootViewController?.menuSwapResizeBehaviorEnabled() == true ? .on : .off
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        _ = window
        return rootViewController?.undoManager
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        applyChromelessWindowStyle(window)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard let eventWindow = notification.object as? NSWindow else { return }
        guard eventWindow == window else { return }
        rootViewController?.windowWillStartLiveResize(eventWindow)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let eventWindow = notification.object as? NSWindow else { return }
        guard eventWindow == window else { return }
        rootViewController?.windowDidEndLiveResize(eventWindow)
    }

    private func showMainWindowWhenReady() {
        guard !didShowMainWindow, let window else { return }
        didShowMainWindow = true
        window.makeKeyAndOrderFront(nil)
        applyChromelessWindowStyle(window)
        alwaysOnTopMenuItem?.state = rootViewController?.menuAlwaysOnTopEnabled() == true ? .on : .off
        showDisplayIDsMenuItem?.state = rootViewController?.menuShowDisplayIDsEnabled() == true ? .on : .off
        centerTileOnJumpMenuItem?.state = rootViewController?.menuCenterTileOnJumpEnabled() == true ? .on : .off
        preserveSizeOnSlotJumpMenuItem?.state = rootViewController?.menuPreserveSizeOnSlotJumpEnabled() == true ? .on : .off
        restoreWindowFrameOnSavepointRecallMenuItem?.state = rootViewController?.menuRestoreWindowFrameOnSavepointRecallEnabled() == true ? .on : .off
        swapResizeBehaviorMenuItem?.state = rootViewController?.menuSwapResizeBehaviorEnabled() == true ? .on : .off
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            self?.applyChromelessWindowStyle(window)
            self?.alwaysOnTopMenuItem?.state = self?.rootViewController?.menuAlwaysOnTopEnabled() == true ? .on : .off
            self?.showDisplayIDsMenuItem?.state = self?.rootViewController?.menuShowDisplayIDsEnabled() == true ? .on : .off
            self?.centerTileOnJumpMenuItem?.state = self?.rootViewController?.menuCenterTileOnJumpEnabled() == true ? .on : .off
            self?.preserveSizeOnSlotJumpMenuItem?.state = self?.rootViewController?.menuPreserveSizeOnSlotJumpEnabled() == true ? .on : .off
            self?.restoreWindowFrameOnSavepointRecallMenuItem?.state = self?.rootViewController?.menuRestoreWindowFrameOnSavepointRecallEnabled() == true ? .on : .off
            self?.swapResizeBehaviorMenuItem?.state = self?.rootViewController?.menuSwapResizeBehaviorEnabled() == true ? .on : .off
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyChromelessWindowStyle(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
        for kind in buttons {
            guard let button = window.standardWindowButton(kind) else { continue }
            button.isHidden = true
            button.isEnabled = false
            button.alphaValue = 0.0
        }
        if let closeButton = window.standardWindowButton(.closeButton),
           let titlebarContainer = closeButton.superview {
            titlebarContainer.isHidden = true
            titlebarContainer.alphaValue = 0.0
        }
    }
}

private final class PermissionGateWindowController: NSWindowController {
    private let onRequestAccessibility: () -> Void
    private let onOpenAccessibilitySettings: () -> Void
    private let onRequestScreenCapture: () -> Void
    private let onOpenScreenCaptureSettings: () -> Void
    private let onRefresh: () -> Void
    private let onContinue: () -> Void

    private let accessibilityToggle = NSButton(checkboxWithTitle: "Accessibility", target: nil, action: nil)
    private let screenCaptureToggle = NSButton(checkboxWithTitle: "Screen Recording", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let requestAccessibilityButton = NSButton(title: "Request", target: nil, action: nil)
    private let openAccessibilitySettingsButton = NSButton(title: "Open Settings", target: nil, action: nil)
    private let requestScreenCaptureButton = NSButton(title: "Request", target: nil, action: nil)
    private let openScreenCaptureSettingsButton = NSButton(title: "Open Settings", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)

    init(
        onRequestAccessibility: @escaping () -> Void,
        onOpenAccessibilitySettings: @escaping () -> Void,
        onRequestScreenCapture: @escaping () -> Void,
        onOpenScreenCaptureSettings: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onContinue: @escaping () -> Void
    ) {
        self.onRequestAccessibility = onRequestAccessibility
        self.onOpenAccessibilitySettings = onOpenAccessibilitySettings
        self.onRequestScreenCapture = onRequestScreenCapture
        self.onOpenScreenCaptureSettings = onOpenScreenCaptureSettings
        self.onRefresh = onRefresh
        self.onContinue = onContinue

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Permissions Required"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.backgroundColor = .windowBackgroundColor

        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let titleLabel = NSTextField(labelWithString: "Allow Required Permissions")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 26, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        let subtitleLabel = NSTextField(
            wrappingLabelWithString: "orcv needs Accessibility and Screen Recording to control windows and show live display previews."
        )
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.alignment = .center

        let accessibilitySection = Self.makePermissionSection(
            toggle: accessibilityToggle,
            description: "Required for shortcuts, focus navigation, and window control.",
            requestButton: requestAccessibilityButton,
            settingsButton: openAccessibilitySettingsButton
        )
        accessibilitySection.translatesAutoresizingMaskIntoConstraints = false

        let screenCaptureSection = Self.makePermissionSection(
            toggle: screenCaptureToggle,
            description: "Required for live previews of your displays and tiles.",
            requestButton: requestScreenCaptureButton,
            settingsButton: openScreenCaptureSettingsButton
        )
        screenCaptureSection.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.bezelStyle = .rounded

        continueButton.translatesAutoresizingMaskIntoConstraints = false
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"

        let footerButtons = NSStackView(views: [refreshButton, continueButton])
        footerButtons.translatesAutoresizingMaskIntoConstraints = false
        footerButtons.orientation = .horizontal
        footerButtons.alignment = .centerY
        footerButtons.spacing = 10
        footerButtons.distribution = .fillEqually

        root.addSubview(iconView)
        root.addSubview(titleLabel)
        root.addSubview(subtitleLabel)
        root.addSubview(accessibilitySection)
        root.addSubview(screenCaptureSection)
        root.addSubview(statusLabel)
        root.addSubview(footerButtons)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            iconView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            subtitleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            accessibilitySection.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
            accessibilitySection.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            accessibilitySection.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            screenCaptureSection.topAnchor.constraint(equalTo: accessibilitySection.bottomAnchor, constant: 12),
            screenCaptureSection.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            screenCaptureSection.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            statusLabel.topAnchor.constraint(equalTo: screenCaptureSection.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            footerButtons.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            footerButtons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 130),
            footerButtons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -130),
            footerButtons.heightAnchor.constraint(equalToConstant: 30),
            footerButtons.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
        ])

        super.init(window: window)

        requestAccessibilityButton.target = self
        requestAccessibilityButton.action = #selector(requestAccessibility)
        openAccessibilitySettingsButton.target = self
        openAccessibilitySettingsButton.action = #selector(openAccessibilitySettings)
        requestScreenCaptureButton.target = self
        requestScreenCaptureButton.action = #selector(requestScreenCapture)
        openScreenCaptureSettingsButton.target = self
        openScreenCaptureSettingsButton.action = #selector(openScreenCaptureSettings)
        refreshButton.target = self
        refreshButton.action = #selector(refreshPermissions)
        continueButton.target = self
        continueButton.action = #selector(continueToApp)

        updateStatus(hasAccessibility: false, hasScreenCapture: false)
        window.center()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func updateStatus(hasAccessibility: Bool, hasScreenCapture: Bool) {
        accessibilityToggle.state = hasAccessibility ? .on : .off
        screenCaptureToggle.state = hasScreenCapture ? .on : .off

        let missing = [
            hasAccessibility ? nil : "Accessibility",
            hasScreenCapture ? nil : "Screen Recording",
        ].compactMap { $0 }

        if missing.isEmpty {
            statusLabel.stringValue = "All required permissions granted."
            continueButton.isEnabled = true
        } else {
            statusLabel.stringValue = "Missing: \(missing.joined(separator: ", "))."
            continueButton.isEnabled = false
        }
    }

    @objc
    private func requestAccessibility() {
        onRequestAccessibility()
    }

    @objc
    private func openAccessibilitySettings() {
        onOpenAccessibilitySettings()
    }

    @objc
    private func requestScreenCapture() {
        onRequestScreenCapture()
    }

    @objc
    private func openScreenCaptureSettings() {
        onOpenScreenCaptureSettings()
    }

    @objc
    private func refreshPermissions() {
        onRefresh()
    }

    @objc
    private func continueToApp() {
        onContinue()
    }

    private static func makePermissionSection(
        toggle: NSButton,
        description: String,
        requestButton: NSButton,
        settingsButton: NSButton
    ) -> NSView {
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        toggle.isEnabled = false

        let descriptionLabel = NSTextField(wrappingLabelWithString: description)
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.maximumNumberOfLines = 0

        requestButton.translatesAutoresizingMaskIntoConstraints = false
        requestButton.bezelStyle = .rounded
        requestButton.controlSize = .small

        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.bezelStyle = .rounded
        settingsButton.controlSize = .small

        let buttonsStack = NSStackView(views: [requestButton, settingsButton])
        buttonsStack.translatesAutoresizingMaskIntoConstraints = false
        buttonsStack.orientation = .horizontal
        buttonsStack.alignment = .centerY
        buttonsStack.spacing = 8
        buttonsStack.distribution = .fillEqually

        let sectionContainer = NSView()
        sectionContainer.translatesAutoresizingMaskIntoConstraints = false
        sectionContainer.wantsLayer = true
        sectionContainer.layer?.cornerRadius = 8
        sectionContainer.layer?.borderWidth = 1
        sectionContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        sectionContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.4).cgColor

        sectionContainer.addSubview(toggle)
        sectionContainer.addSubview(descriptionLabel)
        sectionContainer.addSubview(buttonsStack)

        NSLayoutConstraint.activate([
            toggle.topAnchor.constraint(equalTo: sectionContainer.topAnchor, constant: 10),
            toggle.leadingAnchor.constraint(equalTo: sectionContainer.leadingAnchor, constant: 10),
            toggle.trailingAnchor.constraint(equalTo: sectionContainer.trailingAnchor, constant: -10),

            descriptionLabel.topAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 4),
            descriptionLabel.leadingAnchor.constraint(equalTo: sectionContainer.leadingAnchor, constant: 14),
            descriptionLabel.trailingAnchor.constraint(equalTo: sectionContainer.trailingAnchor, constant: -14),

            buttonsStack.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 8),
            buttonsStack.leadingAnchor.constraint(equalTo: sectionContainer.leadingAnchor, constant: 14),
            buttonsStack.trailingAnchor.constraint(equalTo: sectionContainer.trailingAnchor, constant: -14),
            buttonsStack.heightAnchor.constraint(equalToConstant: 24),
            buttonsStack.bottomAnchor.constraint(equalTo: sectionContainer.bottomAnchor, constant: -10),
        ])

        return sectionContainer
    }
}

private final class OrcvAboutWindowController: NSWindowController {
    private static let githubURL = URL(string: "https://github.com/jasonjmcghee/orcv")
    private static let tagline = "orcv is an infinite-desktop control surface for orchestrating many visual tasks at once"

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "About orcv"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.backgroundColor = NSColor.windowBackgroundColor

        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        root.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let titleLabel = NSTextField(labelWithString: "orcv")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center

        let taglineLabel = NSTextField(wrappingLabelWithString: Self.tagline)
        taglineLabel.translatesAutoresizingMaskIntoConstraints = false
        taglineLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        taglineLabel.textColor = .white
        taglineLabel.alignment = .center
        taglineLabel.maximumNumberOfLines = 0
        taglineLabel.lineBreakMode = .byWordWrapping

        let versionLabel = NSTextField(labelWithString: Self.versionSummary())
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center

        let githubButton = NSButton(title: "GitHub", target: nil, action: nil)
        githubButton.translatesAutoresizingMaskIntoConstraints = false
        githubButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        githubButton.bezelStyle = .rounded
        githubButton.setButtonType(.momentaryPushIn)

        window.contentView = root
        root.addSubview(iconView)
        root.addSubview(titleLabel)
        root.addSubview(taglineLabel)
        root.addSubview(versionLabel)
        root.addSubview(githubButton)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            iconView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 88),
            iconView.heightAnchor.constraint(equalToConstant: 88),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            taglineLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            taglineLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 34),
            taglineLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -34),

            versionLabel.topAnchor.constraint(equalTo: taglineLabel.bottomAnchor, constant: 20),
            versionLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            versionLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            githubButton.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 20),
            githubButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            githubButton.widthAnchor.constraint(equalToConstant: 96),
            githubButton.heightAnchor.constraint(equalToConstant: 30),
            githubButton.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])

        super.init(window: window)

        githubButton.target = self
        githubButton.action = #selector(openGitHub)
        window.center()
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc
    private func openGitHub() {
        guard let url = Self.githubURL else { return }
        NSWorkspace.shared.open(url)
    }

    private static func versionSummary() -> String {
        let bundle = Bundle.main
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
        return "Version \(version) (\(build))"
    }
}
