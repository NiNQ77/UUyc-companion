// 菜单栏：状态 / 重新配置 / 默认设备 / 暂停 / 开机自启 / 退出
import AppKit
import ServiceManagement

final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let coordinator: Coordinator
    private let openWizard: () -> Void
    private let store = ConfigStore.shared

    init(coordinator: Coordinator, openWizard: @escaping () -> Void) {
        self.coordinator = coordinator
        self.openWizard = openWizard
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    func refresh() {
        let active = coordinator.display.isActive
        let symbol = store.config.paused ? "pause.rectangle" : (active ? "ipad.landscape" : "rectangle.on.rectangle")
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "UU远程分辨率伴侣")
        item.button?.toolTip = "UU远程分辨率伴侣：\(coordinator.statusText)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: coordinator.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !UUReader.isTrusted {
            let warn = NSMenuItem(title: "⚠️ 未授权辅助功能，无法识别设备名", action: #selector(openAX), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }
        if store.config.shouldDisablePhysical && !Watchdog.isRunning {
            let warn = NSMenuItem(title: "⚠️ 看门狗未运行，远程时不会关闭物理屏", action: #selector(openLoginItems), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }
        menu.addItem(.separator())

        let restore = action("立即恢复所有屏幕（⌃⌥⌘R）", #selector(restorePhysical))
        restore.isEnabled = coordinator.display.physicalOff || PhysicalDisplays.pending != nil
        menu.addItem(restore)
        let physical = action("远程时关闭物理屏", #selector(toggleDisablePhysical))
        physical.state = store.config.shouldDisablePhysical ? .on : .off
        menu.addItem(physical)
        menu.addItem(.separator())

        menu.addItem(action("重新配置…", #selector(reconfigure), key: ","))

        let defaults = NSMenuItem(title: "默认设备", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let none = action("无", #selector(pickDefault(_:)))
        none.representedObject = ""
        none.state = store.config.defaultDevice == nil ? .on : .off
        sub.addItem(none)
        for d in store.config.devices where d.kind != .computer {
            let it = action("\(d.name)（\(d.sizeLabel)）", #selector(pickDefault(_:)))
            it.representedObject = d.name
            it.state = store.config.defaultDevice == d.name ? .on : .off
            sub.addItem(it)
        }
        defaults.submenu = sub
        menu.addItem(defaults)

        let pause = action("暂停自动切换", #selector(togglePause))
        pause.state = store.config.paused ? .on : .off
        menu.addItem(pause)

        let login = action("开机自启", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(action("退出", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func reconfigure() { openWizard() }

    @objc private func restorePhysical() { coordinator.restorePhysical() }

    @objc private func toggleDisablePhysical() { coordinator.setDisablePhysical(!store.config.shouldDisablePhysical) }

    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    @objc private func openAX() {
        UUReader.requestTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func pickDefault(_ sender: NSMenuItem) {
        let name = sender.representedObject as? String ?? ""
        store.config.defaultDevice = name.isEmpty ? nil : name
        refresh()
    }

    @objc private func togglePause() {
        coordinator.setPaused(!store.config.paused)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.info("⚠️ 开机自启设置失败：\(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "开机自启设置失败"
            alert.informativeText = "\(error.localizedDescription)\n请把 UUDisplay.app 放到「应用程序」文件夹后再试。"
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
