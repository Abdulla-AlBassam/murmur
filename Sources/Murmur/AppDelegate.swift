import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let appState = AppState()
    private lazy var controller = DictationController(appState: appState)

    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private var cleanupItem: NSMenuItem!
    private var mainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Launch.milestone("will finish launching")
        NSApp.mainMenu = buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Launch.milestone("did finish launching")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        statusItem.menu = buildStatusMenu()

        controller.onStateChange = { [weak self] state in
            guard let self else { return }
            self.setIcon(recording: state == .recording)
            switch state {
            case .idle: self.stateItem.title = "Hold fn to dictate"
            case .starting: self.stateItem.title = "Starting…"
            case .recording: self.stateItem.title = "Listening…"
            case .processing: self.stateItem.title = "Polishing…"
            }
        }
        controller.start()

        // A login-item launch stays out of the way; anything the user did
        // deliberately (Spotlight, Finder, Dock) gets the window.
        if !Self.launchedAsLoginItem() {
            showMainWindow(section: nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(section: nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
            event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication
        else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
            == keyAELaunchedAsLogInItem
    }

    private func setIcon(recording: Bool) {
        let name = recording ? "waveform.circle.fill" : "waveform.circle"
        statusItem.button?.image = NSImage(
            systemSymbolName: name, accessibilityDescription: "Murmur")
    }

    // MARK: - Main window

    @objc func openMainWindow() {
        showMainWindow(section: nil)
    }

    func showMainWindow(section: AppState.Section?) {
        if let section { appState.selectedSection = section }
        if mainWindow == nil {
            let root = MainWindowView(appState: appState)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Murmur"
            window.setContentSize(NSSize(width: 720, height: 480))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("MurmurMainWindow")
            if !window.setFrameUsingName("MurmurMainWindow") { window.center() }
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        appState.startPolling()
        Launch.milestone("window visible")
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        appState.stopPolling()
        // Back to a pure menu bar app; dictation keeps running.
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Menus

    private func buildMainMenu() -> NSMenu {
        let menu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Murmur", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(makeItem("Settings…", #selector(showSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Murmur", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        menu.addItem(editItem)

        let window = NSMenu(title: "Window")
        window.addItem(makeItem("Murmur", #selector(openMainWindow), key: "0"))
        window.addItem(.separator())
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        menu.addItem(windowItem)
        NSApp.windowsMenu = window
        return menu
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("Open Murmur", #selector(openMainWindow)))
        menu.addItem(makeItem("History", #selector(showHistory)))
        menu.addItem(makeItem("Dictionary", #selector(showDictionary)))
        menu.addItem(makeItem("Settings…", #selector(showSettings)))
        menu.addItem(.separator())

        cleanupItem = NSMenuItem(title: "Polish dictation", action: #selector(toggleCleanup), keyEquivalent: "")
        cleanupItem.target = self
        cleanupItem.state = appState.polishingEnabled ? .on : .off
        menu.addItem(cleanupItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.delegate = self
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showHistory() { showMainWindow(section: .history) }
    @objc private func showDictionary() { showMainWindow(section: .dictionary) }
    @objc private func showSettings() { showMainWindow(section: .settings) }

    @objc private func toggleCleanup() {
        appState.polishingEnabled.toggle()
        cleanupItem.state = appState.polishingEnabled ? .on : .off
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        cleanupItem.state = appState.polishingEnabled ? .on : .off
    }
}
