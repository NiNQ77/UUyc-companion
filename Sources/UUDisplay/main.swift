// UU远程分辨率伴侣：本机被 UU远程 控制时，按控制端设备自动建虚拟屏并设为主屏，断开后还原
// 调试：UUDisplay --simulate "<设备名>" [秒数=10]  模拟一次连入/断开（不依赖 UU）
//      UUDisplay --simulate "A>B" 8            先按 A 建屏，3 秒后识别为 B 重建
//      UUDisplay --dump-devices                打印从 UU 读到的设备及预填配置
//      UUDisplay --watchdog                    看门狗模式（由 launchd 托管）
import AppKit
import Carbon.HIToolbox
import ServiceManagement

if CommandLine.arguments.contains("--watchdog") { Watchdog.run() }

if CommandLine.arguments.contains("--dump-devices") {
    if !UUReader.hasMainWindow { UUReader.showMainWindow(); Thread.sleep(forTimeInterval: 1) }
    guard let devices = UUReader.readDevices() else { print("未读到 UU 主窗口"); exit(1) }
    for d in devices {
        let cfg = DeviceConfig.make(name: d.name, kind: Presets.guessKind(name: d.name, isComputerGroup: d.isComputerGroup))
        let size = cfg.kind == .computer ? "不切换" : cfg.sizeLabel
        print("\(d.isSelf ? "（本机，排除）" : "")\(d.name)\t→ \(cfg.kind.label)\t\(size)")
    }
    print("控制端：\(UUReader.readControllers() ?? [])")
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = Coordinator()
    let wizard = WizardWindowController()
    var statusBar: StatusBarController?
    private var heartbeatTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var terminating = false

    func applicationDidFinishLaunching(_ note: Notification) {
        Log.info("启动 UUDisplay，辅助功能权限：\(UUReader.isTrusted)")
        statusBar = StatusBarController(coordinator: coordinator) { [weak self] in self?.openWizard() }
        coordinator.onChange = { [weak self] in self?.statusBar?.refresh() }

        // 心跳：看门狗据此判断主程序是否卡死（主线程定时器，卡住即停跳）
        Heartbeat.beat(Heartbeat.appURL)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in Heartbeat.beat(Heartbeat.appURL) }
        installHotkey()

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--simulate"), i + 1 < args.count {
            simulate(name: args[i + 1], seconds: i + 2 < args.count ? Double(args[i + 2]) ?? 10 : 10)
            return
        }

        if !UUReader.isTrusted { UUReader.requestTrust() }
        registerWatchdog()
        coordinator.start()
        if !ConfigStore.shared.isConfigured { openWizard() }
    }

    /// 退出前异步收尾（恢复物理屏、移除虚拟屏），最多等 4 秒
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateNow }
        terminating = true
        let finish = {
            Log.info("退出 UUDisplay")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        var done = false
        coordinator.shutdown { if !done { done = true; finish() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if !done { done = true; finish() } }
        return .terminateLater
    }

    /// 看门狗随 App 注册为 LaunchAgent（KeepAlive），仅在 .app 内运行时可用
    private func registerWatchdog() {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            Log.info("非 .app 运行，跳过看门狗注册（可手动运行 --watchdog）")
            return
        }
        let agent = SMAppService.agent(plistName: "\(Watchdog.label).plist")
        if agent.status != .enabled {
            do { try agent.register() } catch { Log.info("⚠️ 看门狗注册失败：\(error.localizedDescription)") }
        }
        Log.info("看门狗状态：\(agent.status.rawValue)（1=已启用 2=需在登录项中批准）")
    }

    /// 全局快捷键 ⌃⌥⌘R：立即恢复物理屏（Carbon 热键，无需任何权限）
    private func installHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { delegate.coordinator.restorePhysical() }
            return noErr
        }, 1, &spec, me, nil)
        let id = EventHotKeyID(signature: OSType(0x5555_4453), id: 1)  // 'UUDS'
        let err = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | optionKey | controlKey), id,
                                      GetApplicationEventTarget(), 0, &hotKeyRef)
        Log.info(err == noErr ? "已注册快捷键 ⌃⌥⌘R" : "⚠️ 快捷键 ⌃⌥⌘R 注册失败 \(err)")
    }

    private func openWizard() {
        wizard.show { [weak self] in self?.coordinator.configChanged() }
    }

    private func simulate(name: String, seconds: Double) {
        coordinator.display.shouldDisablePhysical = { [weak self] in self?.coordinator.physicalDisableAllowed ?? false }
        coordinator.display.recoverIfNeeded()
        // "A>B"：先按 A 连入，3 秒后识别为 B（模拟名称延迟出现导致的重建）
        let names = name.components(separatedBy: ">")
        Log.info("模拟连入：\(name)，\(Int(seconds)) 秒后断开")
        coordinator.simulatedName = names[0]
        coordinator.handleConnect()
        if names.count > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.coordinator.simulatedName = names[1]
                self?.coordinator.handleConnect()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.coordinator.handleDisconnect()
            self?.coordinator.simulatedName = nil
            Log.info("模拟断开完成")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
