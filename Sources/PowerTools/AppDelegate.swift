import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var controller: AppController!
    private var config = Config.load()
    private let store = Store()
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular app: Dock icon + standard menus, so it's findable and quittable
        // like any app. The menu-bar status item stays for at-a-glance state.
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = buildMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        statusItem.menu = buildStatusMenu()

        // Nudge the Accessibility prompt early — the hotkey tap needs it.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)

        controller = AppController(config: config, store: store)
        controller.onStateChange = { [weak self] state in
            self?.setIcon(recording: state == .recording)
            self?.statusItem.menu = self?.buildStatusMenu()
        }

        showSettings(nil) // open the window on launch so the app is visible

        Task {
            do {
                try await controller.start()
                statusItem.menu = buildStatusMenu()
            } catch {
                log("startup error: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "Power Tools couldn't start"
                alert.informativeText = error.localizedDescription
                    + "\n\nGrant the permission in the Settings window (Permissions section), then reopen the app."
                alert.runModal()
                showSettings(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return true
    }

    // MARK: Settings window

    @objc func showSettings(_ sender: Any?) {
        if settings == nil {
            settings = SettingsWindowController(store: store, config: config, onConfigChange: { [weak self] newConfig in
                self?.config = newConfig
                self?.controller?.config = newConfig  // cleanup mode + theme apply live
                self?.statusItem.menu = self?.buildStatusMenu()
            }, onOpenChat: { [weak self] in
                self?.controller?.openChat()
            })
        }
        settings?.show()
    }

    // MARK: Menus

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Power Tools",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        let ocrMenuItem = NSMenuItem(title: "Capture Text from Screen", action: #selector(captureScreenText), keyEquivalent: "")
        ocrMenuItem.target = self
        appMenu.addItem(ocrMenuItem)
        let chatMenuItem = NSMenuItem(title: "New AI Chat", action: #selector(openChat), keyEquivalent: "n")
        chatMenuItem.target = self
        appMenu.addItem(chatMenuItem)
        let padMenuItem = NSMenuItem(title: "Toggle Macro Pad", action: #selector(toggleMacroPad), keyEquivalent: "b")
        padMenuItem.target = self
        appMenu.addItem(padMenuItem)
        appMenu.addItem(.separator())
        // Close just the focused window (chat/settings); target nil → key window.
        // Distinct from Quit (⌘Q), which shuts down all of Power Tools.
        appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(withTitle: "Hide Power Tools", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Power Tools", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        return main
    }

    private func setIcon(recording: Bool) {
        let symbol = "command"   // ⌘ — the Power Tools mark; red tint below signals recording
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Power Tools")
        image?.isTemplate = !recording
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let stateLabel: String
        switch controller?.state {
        case .recording: stateLabel = "● Recording…"
        case .processing: stateLabel = "◐ Transcribing…"
        default: stateLabel = "Hold \(config.hotkey.displayName) to dictate"
        }
        let stateItem = NSMenuItem(title: stateLabel, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())

        let history = store.recentHistory(5)
        if !history.isEmpty {
            let header = NSMenuItem(title: "Recent (click to copy)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in history {
                let title = entry.polished.count > 60 ? String(entry.polished.prefix(57)) + "…" : entry.polished
                let item = NSMenuItem(title: title, action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.polished
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let ocrItem = NSMenuItem(title: "Capture Text from Screen  (hold \(config.hotkey.displayName) + T)",
                                 action: #selector(captureScreenText), keyEquivalent: "")
        ocrItem.target = self
        menu.addItem(ocrItem)

        let padItem = NSMenuItem(title: "Macro Pad  (hold \(config.hotkey.displayName) + B)",
                                 action: #selector(toggleMacroPad), keyEquivalent: "")
        padItem.target = self
        menu.addItem(padItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Power Tools", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func captureScreenText() {
        controller?.captureScreenText()
    }

    @objc private func openChat() {
        controller?.openChat()
    }

    @objc private func toggleMacroPad() {
        controller?.toggleMacroPad()
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
