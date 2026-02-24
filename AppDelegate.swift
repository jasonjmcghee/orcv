import AppKit
import CoreGraphics
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let mainWindowAutosaveName = "WorkspaceGridMainWindowFrame"

    private var window: NSWindow?
    private var rootViewController: WorkspaceRootViewController?
    private var shortcutManager: ShortcutManager?
    private var shortcutsWindowController: ShortcutSettingsWindowController?
    private weak var macroMenu: NSMenu?
    private weak var macroToggleMenuItem: NSMenuItem?
    private weak var macroReplayMenuItem: NSMenuItem?
    private weak var addToolbarItem: NSToolbarItem?
    private weak var removeToolbarItem: NSToolbarItem?
    private var terminateInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification

        installMainMenu()

        let hasScreenCapture = ScreenCaptureAuthorization.requestIfNeeded()

        let displayManager = VirtualDisplayManager()
        let workspaceStore = WorkspaceStore()
        let pointerRouter = PointerRouter()
        let bundleID = Bundle.main.bundleIdentifier ?? "com.pointworks.workspacegrid"
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Workspace Grid"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .none
        window.toolbarStyle = .unified
        window.toolbar = makeToolbar()
        window.contentViewController = root

        window.setFrameAutosaveName(Self.mainWindowAutosaveName)
        _ = window.setFrameUsingName(Self.mainWindowAutosaveName, force: false)

        self.window = window
        self.rootViewController = root
        root.onMacroStateDidChange = { [weak self] in
            self?.refreshMacroMenuItems()
            self?.refreshToolbarItems()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshMacroMenuItems()
        refreshToolbarItems()
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
            title: "About Workspace Grid",
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

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Workspace Grid"
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let layoutMenuItem = NSMenuItem()
        mainMenu.addItem(layoutMenuItem)

        let layoutMenu = NSMenu(title: "Layout")
        let fullWidthItem = NSMenuItem(
            title: "Full Width Stack",
            action: #selector(applyLayoutFullWidth(_:)),
            keyEquivalent: "1"
        )
        fullWidthItem.keyEquivalentModifierMask = [.control, .option]
        fullWidthItem.target = self
        layoutMenu.addItem(fullWidthItem)

        let twoByTwoItem = NSMenuItem(
            title: "2x2 Grid",
            action: #selector(applyLayout2x2(_:)),
            keyEquivalent: "2"
        )
        twoByTwoItem.keyEquivalentModifierMask = [.control, .option]
        twoByTwoItem.target = self
        layoutMenu.addItem(twoByTwoItem)

        let fullscreenSelectedItem = NSMenuItem(
            title: "Fullscreen Selected Tile",
            action: #selector(showFullscreenSelected(_:)),
            keyEquivalent: "f"
        )
        fullscreenSelectedItem.keyEquivalentModifierMask = [.control, .option]
        fullscreenSelectedItem.target = self
        layoutMenu.addItem(fullscreenSelectedItem)

        layoutMenu.addItem(.separator())

        let dynamicSizingItem = NSMenuItem(
            title: "Tile Size: Dynamic",
            action: #selector(setTileSizingDynamic(_:)),
            keyEquivalent: ""
        )
        dynamicSizingItem.target = self
        layoutMenu.addItem(dynamicSizingItem)

        let fixedSizingItem = NSMenuItem(
            title: "Tile Size: Fixed (Reasonable)",
            action: #selector(setTileSizingFixed(_:)),
            keyEquivalent: ""
        )
        fixedSizingItem.target = self
        layoutMenu.addItem(fixedSizingItem)

        layoutMenuItem.submenu = layoutMenu

        let macroMenuItem = NSMenuItem()
        mainMenu.addItem(macroMenuItem)

        let macroMenu = NSMenu(title: "Macro")
        macroMenu.delegate = self

        let toggleRecordItem = NSMenuItem(
            title: "Record",
            action: #selector(toggleMacroRecording(_:)),
            keyEquivalent: "r"
        )
        toggleRecordItem.keyEquivalentModifierMask = [.control, .option]
        toggleRecordItem.target = self
        macroMenu.addItem(toggleRecordItem)

        let replayItem = NSMenuItem(
            title: "Replay",
            action: #selector(replayMacro(_:)),
            keyEquivalent: "r"
        )
        replayItem.keyEquivalentModifierMask = [.control, .option, .shift]
        replayItem.target = self
        macroMenu.addItem(replayItem)

        macroMenuItem.submenu = macroMenu
        self.macroMenu = macroMenu
        self.macroToggleMenuItem = toggleRecordItem
        self.macroReplayMenuItem = replayItem

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
            .applicationName: "Workspace Grid",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            .credits: NSAttributedString(string: "Controls:\n• Click tile: focus/select one\n• Cmd+Click or Shift+Click: toggle multi-select\n• Click empty background: clear selection\n• Double-Command: teleport toggle"),
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func applyLayoutFullWidth(_ sender: Any?) {
        _ = sender
        rootViewController?.menuApplyLayoutFullWidth()
    }

    @objc
    private func applyLayout2x2(_ sender: Any?) {
        _ = sender
        rootViewController?.menuApplyLayout2x2()
    }

    @objc
    private func showFullscreenSelected(_ sender: Any?) {
        _ = sender
        rootViewController?.menuFullscreenSelected()
    }

    @objc
    private func setTileSizingDynamic(_ sender: Any?) {
        _ = sender
        rootViewController?.menuSetTileSizingMode(.dynamic)
    }

    @objc
    private func setTileSizingFixed(_ sender: Any?) {
        _ = sender
        rootViewController?.menuSetTileSizingMode(.fixed)
    }

    @objc
    private func toggleMacroRecording(_ sender: Any?) {
        _ = sender
        rootViewController?.menuToggleRecording()
        refreshMacroMenuItems()
    }

    @objc
    private func replayMacro(_ sender: Any?) {
        _ = sender
        rootViewController?.menuReplayRecording()
        refreshMacroMenuItems()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === macroMenu {
            refreshMacroMenuItems()
        }
    }

    private func refreshMacroMenuItems() {
        guard let state = rootViewController?.macroState() else { return }
        macroToggleMenuItem?.title = state.isRecording ? "Stop Recording" : "Record"
        macroToggleMenuItem?.isEnabled = !state.isReplaying || state.isRecording
        macroReplayMenuItem?.isEnabled = state.hasRecording && !state.isRecording && !state.isReplaying
    }

    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "WorkspaceGridToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        return toolbar
    }

    private func refreshToolbarItems() {
        addToolbarItem?.isEnabled = true
        removeToolbarItem?.isEnabled = rootViewController?.canRemoveSelectedDisplay() ?? false
    }

    @objc
    private func toolbarNewDisplay(_ sender: Any?) {
        _ = sender
        rootViewController?.menuNewDisplay()
    }

    @objc
    private func toolbarRemoveDisplay(_ sender: Any?) {
        _ = sender
        rootViewController?.menuRemoveFocusedDisplay()
    }
}

extension AppDelegate: NSToolbarDelegate {
    private static let toolbarNewDisplayItemID = NSToolbarItem.Identifier("workspacegrid.newDisplay")
    private static let toolbarRemoveDisplayItemID = NSToolbarItem.Identifier("workspacegrid.removeDisplay")

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.toolbarNewDisplayItemID,
            Self.toolbarRemoveDisplayItemID,
            .space,
            .flexibleSpace
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            Self.toolbarNewDisplayItemID,
            .space,
            Self.toolbarRemoveDisplayItemID
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        _ = toolbar
        _ = flag

        if itemIdentifier == Self.toolbarNewDisplayItemID {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "New Display"
            item.paletteLabel = "New Display"
            item.toolTip = "New Display"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Display")
            item.target = self
            item.action = #selector(toolbarNewDisplay(_:))
            addToolbarItem = item
            return item
        }

        if itemIdentifier == Self.toolbarRemoveDisplayItemID {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Remove Display"
            item.paletteLabel = "Remove Display"
            item.toolTip = "Remove Display"
            item.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove Display")
            item.target = self
            item.action = #selector(toolbarRemoveDisplay(_:))
            removeToolbarItem = item
            return item
        }

        return nil
    }
}
