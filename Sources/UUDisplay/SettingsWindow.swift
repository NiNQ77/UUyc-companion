// 设置窗口（上中下结构）
// 上：工作原理图「控制端 ⇢ 被控 Mac ⇢ 兜底」，点各自按钮向下展开对应面板（同一时间只展开一个）
// 中：立即恢复所有屏幕 / 权限设置 / 功能导览
// 下：关于本应用 / 完全退出（右对齐）
import AppKit
import ServiceManagement
import SwiftUI
import SystemSettingsKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case controller, controlled, fallback
    var id: String { rawValue }
}

final class SettingsModel: ObservableObject {
    // 注意：SwiftUI 的 @State 在仅有 Command Line Tools 时无法编译（宏插件缺失），界面状态统一放在 ObservableObject 里
    @Published var expanded: SettingsPane?
    @Published var autoVirtual: Bool
    @Published var disablePhysical: Bool
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    @Published var watchdogEnabled: Bool
    @Published var watchdogRunning = Watchdog.isRunning
    @Published var physicalOff = PhysicalDisplays.pending != nil
    @Published var savedHint = false

    let devices = WizardModel()
    var onConfigChanged: (() -> Void)?
    var setDisablePhysical: ((Bool) -> Void)?
    var setPaused: ((Bool) -> Void)?
    var restorePhysical: (() -> Void)?
    var openPermissions: (() -> Void)?
    var openTour: (() -> Void)?
    private var timer: Timer?
    private let store = ConfigStore.shared

    init() {
        autoVirtual = !store.config.paused
        disablePhysical = store.config.shouldDisablePhysical
        watchdogEnabled = store.config.shouldRunWatchdog
    }

    var fallbackAvailable: Bool { autoVirtual && disablePhysical }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate() }

    func refresh() {
        let running = Watchdog.isRunning
        if running != watchdogRunning { watchdogRunning = running }
        let off = PhysicalDisplays.pending != nil
        if off != physicalOff { physicalOff = off }
        let login = SMAppService.mainApp.status == .enabled
        if login != launchAtLogin { launchAtLogin = login }
    }

    /// 点同一个按钮再次收起；兜底面板只在开启软关闭后可展开
    func toggle(_ pane: SettingsPane) {
        if pane == .fallback && !fallbackAvailable { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            expanded = expanded == pane ? nil : pane
        }
    }

    func saveDevices() {
        devices.save()
        onConfigChanged?()
        savedHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.savedHint = false }
    }

    func toggleLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "设置失败：\(error.localizedDescription)。请把 UU远程伴侣 放在「应用程序」文件夹后再试。"
            Log.info("⚠️ 开机启动设置失败：\(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func toggleAutoVirtual(_ on: Bool) {
        autoVirtual = on
        setPaused?(!on)
        Log.info("设置：自动启动虚拟屏 → \(on ? "开" : "关")")
        if !fallbackAvailable && expanded == .fallback { withAnimation { expanded = nil } }
    }

    func toggleDisablePhysical(_ on: Bool) {
        disablePhysical = on
        setDisablePhysical?(on)
        Log.info("设置：自动软关闭物理屏 → \(on ? "开" : "关")")
        if !on && expanded == .fallback { withAnimation { expanded = nil } }
    }

    /// 只有在这里开启，看门狗才会安装为 LaunchAgent 并加载；关闭即卸载
    func toggleWatchdog(_ on: Bool) {
        watchdogEnabled = on
        store.config.watchdogEnabled = on
        Log.info("设置：看门狗 → \(on ? "开" : "关")")
        if on { WatchdogAgent.ensureInstalled() } else { WatchdogAgent.uninstall() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版"
        let credits = NSAttributedString(
            string: "平板或手机通过 UU远程 控制这台 Mac 时，自动建立分辨率完全匹配的虚拟屏，断开后自动还原。\n\n开源组件：PermissionFlow、TourKit、FreeDisplay 虚拟屏接口声明（均为 MIT 协议）",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "UU远程伴侣",
            .applicationVersion: version,
            .credits: credits,
        ])
    }

    /// 完全退出：停掉本次登录中的看门狗（不卸载，下次打开 App 或重新登录时恢复），再退出主程序
    func quitCompletely() {
        Log.info("完全退出：停止看门狗并退出主程序")
        WatchdogAgent.stopForSession()
        NSApp.terminate(nil)
    }
}

// MARK: - 快捷键示意图（⌃ ⌥ ⌘ 9 四个键）

private struct HotkeyCap: View {
    let symbol: String
    var name: String? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.accentColor)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 2)
            .overlay(
                VStack(spacing: 2) {
                    Text(symbol).font(.system(size: name == nil ? 28 : 24, weight: .semibold))
                    if let name { Text(name).font(.system(size: 11, weight: .medium)) }
                }
                .foregroundStyle(.white)
            )
            .frame(width: name == nil ? 64 : 78, height: 64)
    }
}

struct HotkeyKeysView: View {
    var body: some View {
        HStack(spacing: 10) {
            HotkeyCap(symbol: "⌃", name: "control")
            plus
            HotkeyCap(symbol: "⌥", name: "option")
            plus
            HotkeyCap(symbol: "⌘", name: "command")
            plus
            HotkeyCap(symbol: "9")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("快捷键示意图：同时按下 control、option、command 和 9")
    }

    private var plus: some View {
        Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(.secondary)
    }
}

// MARK: - 面板

private struct Card<Content: View>: View {
    let icon: String
    let title: String
    let tag: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 24)
                Text(title).font(.headline)
                Text(tag).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - 工作原理图

/// 虚线箭头，中间带说明文字；纵向对齐到图标中线
private struct DashedConnector: View {
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 5))
                        p.addLine(to: CGPoint(x: w - 8, y: 5))
                    }
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 6]))
                    Path { p in
                        p.move(to: CGPoint(x: w - 10, y: 0))
                        p.addLine(to: CGPoint(x: w, y: 5))
                        p.addLine(to: CGPoint(x: w - 10, y: 10))
                    }
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 10)
        }
        .padding(.top, 44)  // 文字 + 线大约落在 128 图标的垂直中部
        .frame(minWidth: 70, maxWidth: .infinity)
    }
}

/// 控制端图标：平板 + 手机 组合
private struct ControllerIcon: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "ipad.landscape")
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 112)
                .offset(x: -8, y: -14)
            Image(systemName: "iphone")
                .resizable().aspectRatio(contentMode: .fit)
                .frame(height: 64)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        }
        .frame(width: 128, height: 128)
    }
}

private struct FlowNode<Icon: View>: View {
    let caption: String
    let buttonTitle: String
    var enabled = true
    var selected = false
    var hint: String? = nil
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        VStack(spacing: 10) {
            icon()
                .font(.system(size: 96, weight: .light))
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.45))
                .frame(width: 128, height: 128)
            Text(caption).font(.subheadline.weight(.medium)).foregroundStyle(enabled ? .primary : .secondary)
            Group {
                if selected {
                    Button(action: action) { Label(buttonTitle, systemImage: "chevron.up") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(action: action) { Label(buttonTitle, systemImage: "chevron.down") }
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
            .disabled(!enabled)
            .help(hint ?? "")
        }
        .frame(width: 180)
    }
}

// MARK: - 展开面板

/// 被控制端：开机启动 / 自动启动虚拟屏 / 自动软关闭物理屏
struct ControlledPanel: View {
    @ObservedObject var model: SettingsModel

    private func row(_ title: String, _ detail: String, isOn: Binding<Bool>, enabled: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(enabled ? .primary : .secondary)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().disabled(!enabled)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("设置被控制端").font(.title3.bold())
            row("开机时启动 UU远程伴侣",
                "登录 Mac 后自动在菜单栏运行，随时准备接收 UU 远程连入。",
                isOn: Binding(get: { model.launchAtLogin }, set: { model.toggleLaunchAtLogin($0) }))
            if let err = model.loginError {
                Text(err).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            row("自动启动虚拟屏",
                "平板或手机连入时，自动建立分辨率与它一致的虚拟屏并设为主屏；断开后自动移除。关闭后连入时不做任何改动。",
                isOn: Binding(get: { model.autoVirtual }, set: { model.toggleAutoVirtual($0) }))
            Divider()
            row("自动软关闭除虚拟屏之外的显示器",
                "远程期间暂时关闭外接显示器和内建屏，只保留那块虚拟屏，窗口不会跑到看不见的地方；断开后自动恢复。电脑连入时不受影响。打开后可在「兜底选项」里查看万一屏幕没恢复时的找回方法。",
                isOn: Binding(get: { model.disablePhysical }, set: { model.toggleDisablePhysical($0) }),
                enabled: model.autoVirtual)
            if !model.autoVirtual {
                Text("需要先打开「自动启动虚拟屏」。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 兜底选项：快捷键 + 看门狗
struct FallbackPanel: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("兜底选项").font(.title3.bold())
                Text("万一远程结束后屏幕没有自动恢复，可以用下面的方式找回。").foregroundStyle(.secondary)
            }

            Card(icon: "keyboard", title: "快捷键", tag: "始终可用") {
                Text("坐在 Mac 前、屏幕黑着时，同时按下 **⌃ control + ⌥ option + ⌘ command + 9**，立即恢复所有物理屏。虚拟屏保留，本次连接内不再关闭物理屏。")
                    .fixedSize(horizontal: false, vertical: true)
                HotkeyKeysView()
                Text("设置窗口和菜单栏里的「立即恢复所有屏幕」效果相同。")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Card(icon: "shield.lefthalf.filled", title: "看门狗", tag: "可选") {
                Text("一个独立的后台小程序，每秒检查一次。出现以下任一情况时，自动恢复物理屏：")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("• UU远程伴侣 崩溃或被强制退出")
                    Text("• UU远程伴侣 卡住超过 10 秒（会先结束它）")
                    Text("• UU 远程已断开 5 秒，屏幕却还关着")
                }
                .font(.callout)
                Text("看门狗被结束后，系统会在 1 秒内把它重新拉起。")
                    .font(.callout).foregroundStyle(.secondary)

                Divider()
                Text("需要的权限").font(.subheadline.bold())
                Text("开启后，看门狗会安装为登录项（后台项目），macOS 会提示「已添加后台项目」。如果它在「系统设置 › 通用 › 登录项与扩展」中被关闭，需要打开 UU远程伴侣 的开关。它不需要辅助功能等其他权限。只有在这里开启时才会安装并加载到内存，关闭即卸载。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Toggle(isOn: Binding(get: { model.watchdogEnabled }, set: { model.toggleWatchdog($0) })) {
                        Text("开启看门狗")
                    }
                    .toggleStyle(.switch)
                    if model.watchdogEnabled {
                        Label(model.watchdogRunning ? "运行中" : "未运行",
                              systemImage: model.watchdogRunning ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(model.watchdogRunning ? .green : .orange)
                        if !model.watchdogRunning {
                            Button("打开登录项与扩展") { SystemSettings.open(.loginItems) }
                        }
                    }
                }
            }

            if !model.watchdogEnabled {
                Label("未开启看门狗时，如果 UU远程伴侣 意外退出，物理屏会保持关闭：重新打开 UU远程伴侣 或重启 Mac 即可恢复。",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 整体

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// 离屏渲染时展开内容不放进 ScrollView（便于检查完整排版）
    var forRender = false

    @ViewBuilder private var expandedContent: some View {
        switch model.expanded {
        case .controller:
            WizardView(model: model.devices, openPermissions: model.openPermissions, embedded: true,
                       savedHint: model.savedHint) { model.saveDevices() }
                .frame(height: 500)
        case .controlled:
            ControlledPanel(model: model)
        case .fallback:
            if forRender {
                FallbackPanel(model: model)
            } else {
                ScrollView { FallbackPanel(model: model) }.frame(height: 520)
            }
        case .none:
            EmptyView()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 上：工作原理图
            HStack(alignment: .top, spacing: 0) {
                FlowNode(caption: "控制端设备", buttonTitle: "设置控制端",
                         selected: model.expanded == .controller, action: { model.toggle(.controller) }) {
                    ControllerIcon()
                }
                DashedConnector(label: "UU 远程控制")
                FlowNode(caption: "被控制的 Mac", buttonTitle: "设置被控制端",
                         selected: model.expanded == .controlled, action: { model.toggle(.controlled) }) {
                    Image(systemName: "desktopcomputer")
                }
                DashedConnector(label: "关闭物理屏时")
                FlowNode(caption: "兜底保护", buttonTitle: "兜底选项",
                         enabled: model.fallbackAvailable, selected: model.expanded == .fallback,
                         hint: model.fallbackAvailable ? nil : "先在「设置被控制端」中打开「自动软关闭除虚拟屏之外的显示器」",
                         action: { model.toggle(.fallback) }) {
                    Image(systemName: "lifepreserver")
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 20)

            if model.expanded != nil {
                expandedContent
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()

            // 中：常用操作
            HStack(spacing: 14) {
                Button { model.restorePhysical?() } label: {
                    Label("立即恢复所有屏幕", systemImage: "display.2")
                }
                .disabled(!model.physicalOff)
                .help(model.physicalOff ? "等同快捷键 ⌃ control + ⌥ option + ⌘ command + 9" : "当前没有被关闭的物理屏")
                Button { model.openPermissions?() } label: { Label("权限设置", systemImage: "hand.raised") }
                Button { model.openTour?() } label: { Label("功能导览", systemImage: "sparkles") }
            }
            .controlSize(.large)
            .padding(.vertical, 16)

            Divider()

            // 下：关于 / 完全退出
            HStack(spacing: 10) {
                Spacer()
                Button("关于本应用") { model.showAbout() }
                Button("完全退出", role: .destructive) { model.quitCompletely() }
                    .help("退出 UU远程伴侣，并停止本次登录中的看门狗")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 900)
        .clipped()
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    private var model: SettingsModel?
    var openPermissions: (() -> Void)?
    var openTour: (() -> Void)?
    var onConfigChanged: (() -> Void)?
    var setDisablePhysical: ((Bool) -> Void)?
    var setPaused: ((Bool) -> Void)?
    var restorePhysical: (() -> Void)?

    /// - Parameter pane: 打开时展开的面板，nil 表示全部收起
    func show(pane: SettingsPane? = nil) {
        if let window, let model {
            if let pane, model.expanded != pane { model.toggle(pane) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = SettingsModel()
        model.expanded = (pane == .fallback && !model.fallbackAvailable) ? nil : pane
        model.onConfigChanged = onConfigChanged
        model.setDisablePhysical = setDisablePhysical
        model.setPaused = setPaused
        model.restorePhysical = restorePhysical
        model.openPermissions = openPermissions
        model.openTour = openTour
        model.start()
        self.model = model
        // 用 NSHostingController 作为内容控制器：窗口尺寸随 SwiftUI 内容（展开/收起）自动调整。
        // 注意：直接给 NSHostingView 设 sizingOptions = .preferredContentSize 会让窗口初始尺寸为 0×0（看不见）
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.title = "UU远程伴侣 设置"
        w.isReleasedWhenClosed = false
        w.setContentSize(hosting.view.fittingSize)  // 先定好尺寸再居中，否则按 0×0 居中会偏到右侧
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.model?.stop()
            self?.model = nil
            self?.window = nil
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 调试：渲染各状态为 PNG（--render-settings <目录>）
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cases: [(String, SettingsPane?, Bool, Bool)] = [
            ("collapsed-physical-off", nil, false, false),
            ("collapsed-physical-on", nil, true, false),
            ("controller", .controller, false, false),
            ("controlled", .controlled, true, false),
            ("fallback", .fallback, true, true),
        ]
        for (name, pane, physical, watchdog) in cases {
            let model = SettingsModel()
            model.autoVirtual = true
            model.disablePhysical = physical
            model.watchdogEnabled = watchdog
            model.watchdogRunning = false
            model.expanded = pane
            let view = NSHostingView(rootView: SettingsView(model: model, forRender: true))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("settings-\(name).png"))
            }
        }
    }
}
