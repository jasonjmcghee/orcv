import AppKit
import CoreGraphics
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let mainWindowAutosaveName = "orcvMainWindowFrame"

    private var window: NSWindow?
    private var rootViewController: WorkspaceRootViewController?
    private var shortcutManager: ShortcutManager?
    private var shortcutsWindowController: ShortcutSettingsWindowController?
    private var terminateInProgress = false
    private var didShowMainWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification

        installMainMenu()

        let hasScreenCapture = ScreenCaptureAuthorization.requestIfNeeded()

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
            hasScreenCaptureAccess: hasScreenCapture
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
        fileMenu.addItem(.separator())

        let fullscreenSelectedItem = NSMenuItem(
            title: "Fullscreen Selected",
            action: #selector(showFullscreenSelected(_:)),
            keyEquivalent: ""
        )
        fullscreenSelectedItem.target = self
        fileMenu.addItem(fullscreenSelectedItem)
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

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)

        let viewMenu = NSMenu(title: "View")
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

        viewMenu.addItem(.separator())
        let fullscreenItem = NSMenuItem(
            title: "Fullscreen Selected",
            action: #selector(showFullscreenSelected(_:)),
            keyEquivalent: "f"
        )
        fullscreenItem.keyEquivalentModifierMask = [.command, .shift]
        fullscreenItem.target = self
        viewMenu.addItem(fullscreenItem)
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
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
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "orcv",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            .credits: NSAttributedString(string: "Controls:\n• Drag displays to position them on canvas\n• Drag empty background to move the app window\n• Hold Space while hovering/focused to move window with cursor\n• Use Shortcuts settings to record key bindings"),
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
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
    private func showFullscreenSelected(_ sender: Any?) {
        _ = sender
        rootViewController?.menuFullscreenSelected()
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

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        _ = window
        return rootViewController?.undoManager
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        applyChromelessWindowStyle(window)
    }

    private func showMainWindowWhenReady() {
        guard !didShowMainWindow, let window else { return }
        didShowMainWindow = true
        window.makeKeyAndOrderFront(nil)
        applyChromelessWindowStyle(window)
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            self?.applyChromelessWindowStyle(window)
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
