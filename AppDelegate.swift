import AppKit
import CoreGraphics
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var rootViewController: WorkspaceRootViewController?
    private var shortcutManager: ShortcutManager?
    private var shortcutsWindowController: ShortcutSettingsWindowController?

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
        window.titleVisibility = .visible
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentViewController = root

        self.window = window
        self.rootViewController = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        rootViewController?.flushStateNow()
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
}
