import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = DictationController()

    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let modelItem = NSMenuItem(title: "Checking speech model…", action: nil, keyEquivalent: "")
    private var cleanupItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!

    private var historyWindow: NSWindow?
    private var dictionaryWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        statusItem.menu = buildMenu()

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
        controller.onModelStatusChange = { [weak self] status in
            self?.modelItem.title = status
        }
        controller.start()
    }

    private func setIcon(recording: Bool) {
        let name = recording ? "waveform.circle.fill" : "waveform.circle"
        statusItem.button?.image = NSImage(
            systemSymbolName: name, accessibilityDescription: "Murmur")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        stateItem.isEnabled = false
        modelItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(modelItem)
        menu.addItem(.separator())

        menu.addItem(makeItem("History…", #selector(showHistory)))
        menu.addItem(makeItem("Dictionary…", #selector(showDictionary)))
        menu.addItem(.separator())

        cleanupItem = NSMenuItem(
            title: "AI clean-up", action: #selector(toggleCleanup), keyEquivalent: "")
        cleanupItem.target = self
        cleanupItem.state = controller.cleaner.isEnabled ? .on : .off
        menu.addItem(cleanupItem)

        launchAtLoginItem = NSMenuItem(
            title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())

        menu.addItem(makeItem("Accessibility Settings…", #selector(openAccessibilitySettings)))
        menu.addItem(makeItem("Microphone Settings…", #selector(openMicrophoneSettings)))
        menu.addItem(makeItem("Globe Key Tip…", #selector(showGlobeKeyTip)))
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Windows

    @objc private func showHistory() {
        presentWindow(&historyWindow, title: "Dictation History") {
            HistoryView(store: .shared)
        }
    }

    @objc private func showDictionary() {
        presentWindow(&dictionaryWindow, title: "Personal Dictionary") {
            DictionaryView(store: .shared)
        }
    }

    private func presentWindow<Content: View>(
        _ slot: inout NSWindow?, title: String, @ViewBuilder content: () -> Content
    ) {
        if slot == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
            window.title = title
            window.isReleasedWhenClosed = false
            window.center()
            slot = window
        }
        slot?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Toggles

    @objc private func toggleCleanup() {
        controller.cleaner.isEnabled.toggle()
        cleanupItem.state = controller.cleaner.isEnabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.info("Murmur: launch at login toggle failed: \(error)")
        }
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: - Settings links

    @objc private func openAccessibilitySettings() {
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openMicrophoneSettings() {
        openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    @objc private func showGlobeKeyTip() {
        let alert = NSAlert()
        alert.messageText = "Stop the 🌐 key opening the emoji picker"
        alert.informativeText = """
        Murmur uses the fn (🌐) key as its push-to-talk button. To stop macOS \
        also reacting to it, open System Settings → Keyboard and set \
        “Press 🌐 key to” to “Do Nothing”.
        """
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openSettingsPane("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        }
    }

    private func openSettingsPane(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
