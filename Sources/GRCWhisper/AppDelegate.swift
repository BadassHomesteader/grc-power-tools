import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var controller: AppController!
    private let config = Config.load()
    private let store = Store()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        statusItem.menu = buildMenu()

        // Nudge the Accessibility prompt early — the hotkey tap needs it.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        controller = AppController(config: config, store: store)
        controller.onStateChange = { [weak self] state in
            self?.setIcon(recording: state == .recording)
            self?.statusItem.menu = self?.buildMenu()
        }

        Task {
            do {
                try await controller.start()
                statusItem.menu = buildMenu()
            } catch {
                log("startup error: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "GRC Whisper couldn't start"
                alert.informativeText = error.localizedDescription
                    + "\n\nGrant the permission in System Settings ▸ Privacy & Security, then relaunch."
                alert.runModal()
            }
        }
    }

    private func setIcon(recording: Bool) {
        let symbol = recording ? "mic.fill" : "mic"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "GRC Whisper")
        image?.isTemplate = !recording
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    private func buildMenu() -> NSMenu {
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
                let title = entry.polished.count > 60
                    ? String(entry.polished.prefix(57)) + "…"
                    : entry.polished
                let item = NSMenuItem(title: title, action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.polished
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let polishMenu = NSMenu()
        for mode in Config.PolishMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(setPolishMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = config.polish == mode ? .on : .off
            polishMenu.addItem(item)
        }
        let polishItem = NSMenuItem(title: "Cleanup", action: nil, keyEquivalent: "")
        menu.addItem(polishItem)
        menu.setSubmenu(polishMenu, for: polishItem)

        let hotkeyMenu = NSMenu()
        for hk in Config.Hotkey.allCases {
            let item = NSMenuItem(title: hk.displayName, action: #selector(setHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = hk.rawValue
            item.state = config.hotkey == hk ? .on : .off
            hotkeyMenu.addItem(item)
        }
        let hotkeyItem = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        menu.addItem(hotkeyItem)
        menu.setSubmenu(hotkeyMenu, for: hotkeyItem)

        menu.addItem(.separator())

        let doctorItem = NSMenuItem(title: "Permission Doctor…", action: #selector(runDoctor), keyEquivalent: "")
        doctorItem.target = self
        menu.addItem(doctorItem)

        let dataItem = NSMenuItem(title: "Open Data Folder", action: #selector(openDataFolder), keyEquivalent: "")
        dataItem.target = self
        menu.addItem(dataItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit GRC Whisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        return menu
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func setPolishMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = Config.PolishMode(rawValue: raw) else { return }
        var cfg = Config.load()
        cfg.polish = mode
        cfg.save()
        relaunchNotice(ifChanged: false)
    }

    @objc private func setHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let hk = Config.Hotkey(rawValue: raw) else { return }
        var cfg = Config.load()
        let changed = cfg.hotkey != hk
        cfg.hotkey = hk
        cfg.save()
        relaunchNotice(ifChanged: changed)
    }

    private func relaunchNotice(ifChanged changed: Bool) {
        statusItem.menu = buildMenu()
        if changed {
            let alert = NSAlert()
            alert.messageText = "Hotkey saved"
            alert.informativeText = "Quit and reopen GRC Whisper to apply the new hotkey."
            alert.runModal()
        }
    }

    @objc private func runDoctor() {
        Task {
            let report = await Doctor.report()
            let alert = NSAlert()
            alert.messageText = "Permission Doctor"
            alert.informativeText = report
            alert.runModal()
        }
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.open(Config.appSupportDir)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("launch-at-login toggle failed: \(error)")
        }
        statusItem.menu = buildMenu()
    }
}
