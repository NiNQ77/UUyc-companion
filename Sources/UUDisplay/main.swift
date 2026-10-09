// UU远程分辨率伴侣：本机被 UU远程 控制时，按控制端设备自动建虚拟屏并设为主屏，断开后还原
// 调试：UUDisplay --simulate "<设备名>" [秒数=10]  模拟一次连入/断开（不依赖 UU）
//      UUDisplay --simulate "A>B" 8            先按 A 建屏，3 秒后识别为 B 重建
//      UUDisplay --dump-devices                打印从 UU 读到的设备及预填配置
import AppKit

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

    func applicationDidFinishLaunching(_ note: Notification) {
        Log.info("启动 UUDisplay，辅助功能权限：\(UUReader.isTrusted)")
        statusBar = StatusBarController(coordinator: coordinator) { [weak self] in self?.openWizard() }
        coordinator.onChange = { [weak self] in self?.statusBar?.refresh() }

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--simulate"), i + 1 < args.count {
            simulate(name: args[i + 1], seconds: i + 2 < args.count ? Double(args[i + 2]) ?? 10 : 10)
            return
        }

        if !UUReader.isTrusted { UUReader.requestTrust() }
        coordinator.start()
        if !ConfigStore.shared.isConfigured { openWizard() }
    }

    func applicationWillTerminate(_ note: Notification) {
        coordinator.shutdown()
        Log.info("退出 UUDisplay")
    }

    private func openWizard() {
        wizard.show { [weak self] in self?.coordinator.configChanged() }
    }

    private func simulate(name: String, seconds: Double) {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
