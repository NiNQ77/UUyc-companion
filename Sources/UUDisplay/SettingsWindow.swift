// 设置窗口：左侧竖排栏目（设备配置 / 屏幕与兜底），右侧为对应面板
import AppKit
import SwiftUI
import SystemSettingsKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case devices, displays
    var id: String { rawValue }
    var title: String {
        switch self {
        case .devices: return "设备配置"
        case .displays: return "屏幕与兜底"
        }
    }
    var icon: String {
        switch self {
        case .devices: return "ipad.and.iphone"
        case .displays: return "display.2"
        }
    }
}

final class SettingsModel: ObservableObject {
    // 注意：SwiftUI 的 @State 在仅有 Command Line Tools 时无法编译（宏插件缺失），界面状态统一放在 ObservableObject 里
    @Published var pane: SettingsPane = .devices
    @Published var disablePhysical: Bool
    @Published var watchdogEnabled: Bool
    @Published var watchdogRunning = Watchdog.isRunning
    @Published var savedHint = false

    let devices = WizardModel()
    var onConfigChanged: (() -> Void)?
    var setDisablePhysical: ((Bool) -> Void)?
    private var timer: Timer?
    private let store = ConfigStore.shared

    init() {
        disablePhysical = store.config.shouldDisablePhysical
        watchdogEnabled = store.config.shouldRunWatchdog
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate() }

    func refresh() {
        let running = Watchdog.isRunning
        if running != watchdogRunning { watchdogRunning = running }
    }

    func saveDevices() {
        devices.save()
        onConfigChanged?()
        savedHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.savedHint = false }
    }

    func toggleDisablePhysical(_ on: Bool) {
        disablePhysical = on
        setDisablePhysical?(on)
        Log.info("设置：远程时软关闭物理屏 → \(on ? "开" : "关")")
    }

    /// 只有在这里开启，看门狗才会安装为 LaunchAgent 并加载；关闭即卸载
    func toggleWatchdog(_ on: Bool) {
        watchdogEnabled = on
        store.config.watchdogEnabled = on
        Log.info("设置：看门狗 → \(on ? "开" : "关")")
        if on { WatchdogAgent.ensureInstalled() } else { WatchdogAgent.uninstall() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }
}

// MARK: - 键盘示意图（Mac 键盘左半边，高亮 ⌃ ⌥ ⌘ R）

private struct KeyCap: View {
    let label: String
    var sub: String? = nil
    var width: CGFloat = 1
    var height: CGFloat = 1
    var highlighted = false
    static let unit: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(highlighted ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(highlighted ? 0 : 0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 1)
            .overlay(
                VStack(spacing: 1) {
                    Text(label).font(.system(size: sub == nil ? 13 : 14, weight: highlighted ? .bold : .regular))
                    if let sub { Text(sub).font(.system(size: 8.5)) }
                }
                .foregroundStyle(highlighted ? Color.white : Color.primary.opacity(0.75))
            )
            .frame(width: KeyCap.unit * width + 5 * (width - 1), height: KeyCap.unit * height)
    }
}

struct KeyboardLeftHalfView: View {
    private func row(_ keys: [(String, CGFloat)]) -> some View {
        HStack(spacing: 5) { ForEach(Array(keys.enumerated()), id: \.offset) { KeyCap(label: $0.element.0, width: $0.element.1) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                KeyCap(label: "esc", width: 1.4, height: 0.6)
                ForEach(1...5, id: \.self) { KeyCap(label: "F\($0)", height: 0.6) }
            }
            row([("`", 1), ("1", 1), ("2", 1), ("3", 1), ("4", 1), ("5", 1), ("6", 1)])
            HStack(spacing: 5) {
                KeyCap(label: "⇥", sub: "tab", width: 1.5)
                ForEach(["Q", "W", "E"], id: \.self) { KeyCap(label: $0) }
                KeyCap(label: "R", highlighted: true)
                KeyCap(label: "T")
            }
            HStack(spacing: 5) {
                KeyCap(label: "⇪", sub: "caps lock", width: 1.8)
                ForEach(["A", "S", "D", "F", "G"], id: \.self) { KeyCap(label: $0) }
            }
            HStack(spacing: 5) {
                KeyCap(label: "⇧", sub: "shift", width: 2.3)
                ForEach(["Z", "X", "C", "V", "B"], id: \.self) { KeyCap(label: $0) }
            }
            HStack(spacing: 5) {
                KeyCap(label: "fn")
                KeyCap(label: "⌃", sub: "control", highlighted: true)
                KeyCap(label: "⌥", sub: "option", highlighted: true)
                KeyCap(label: "⌘", sub: "command", width: 1.3, highlighted: true)
                KeyCap(label: "", width: 3)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
        .accessibilityLabel("键盘示意图：同时按下 control、option、command 和 R")
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

struct DisplaysPanel: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("屏幕与兜底").font(.title2.bold())

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(get: { model.disablePhysical }, set: { model.toggleDisablePhysical($0) })) {
                        Text("远程时软关闭物理屏").font(.headline)
                    }
                    .toggleStyle(.switch)
                    Text("平板或手机连入后，除虚拟屏以外的显示器（外接显示器、内建屏）会被暂时关闭，远程期间只保留一块分辨率精确匹配的虚拟屏；断开后自动恢复。电脑连入时不做任何改动。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                if model.disablePhysical {
                    Text("兜底方式").font(.title3.bold()).padding(.top, 4)
                    Text("万一屏幕没有自动恢复，可以用下面的方式找回。")
                        .foregroundStyle(.secondary)

                    Card(icon: "keyboard", title: "快捷键", tag: "始终可用") {
                        Text("坐在 Mac 前、屏幕黑着时，同时按下 **⌃ control + ⌥ option + ⌘ command + R**，立即恢复所有物理屏。虚拟屏保留，本次连接内不再关闭物理屏。")
                            .fixedSize(horizontal: false, vertical: true)
                        KeyboardLeftHalfView()
                        Text("菜单栏图标里的「立即恢复所有屏幕」效果相同。")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    Card(icon: "shield.lefthalf.filled", title: "看门狗", tag: "可选") {
                        Text("一个独立的后台小程序，每秒检查一次。出现以下任一情况时，自动恢复物理屏：")
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("• UUDisplay 崩溃或被强制退出")
                            Text("• UUDisplay 卡住超过 10 秒（会先结束它）")
                            Text("• UU 远程已断开 5 秒，屏幕却还关着")
                        }
                        .font(.callout)
                        Text("看门狗被结束后，系统会在 1 秒内把它重新拉起。")
                            .font(.callout).foregroundStyle(.secondary)

                        Divider()
                        Text("需要的权限").font(.subheadline.bold())
                        Text("开启后，看门狗会安装为登录项（后台项目），macOS 会提示「已添加后台项目」。如果它在「系统设置 › 通用 › 登录项与扩展」中被关闭，需要打开 UUDisplay 的开关。它不需要辅助功能等其他权限。只有在这里开启时才会安装并加载到内存，关闭即卸载。")
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
                        Label("未开启看门狗时，如果 UUDisplay 意外退出，物理屏会保持关闭：重新打开 UUDisplay 或重启 Mac 即可恢复。",
                              systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var openPermissions: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            // 左侧竖排栏目（自绘，避免 List 依赖 @State 选择状态，也便于离屏渲染检查）
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsPane.allCases) { pane in
                    let selected = model.pane == pane
                    Button { model.pane = pane } label: {
                        Label(pane.title, systemImage: pane.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : .clear))
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 16)
            .frame(width: 180)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))

            Divider()

            Group {
                switch model.pane {
                case .devices:
                    WizardView(model: model.devices, openPermissions: openPermissions, embedded: true,
                               savedHint: model.savedHint) { model.saveDevices() }
                case .displays:
                    DisplaysPanel(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 1040, minHeight: 620)
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    private var model: SettingsModel?
    var openPermissions: (() -> Void)?
    var onConfigChanged: (() -> Void)?
    var setDisablePhysical: ((Bool) -> Void)?

    func show(pane: SettingsPane = .devices) {
        if let window, let model {
            model.pane = pane
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = SettingsModel()
        model.pane = pane
        model.onConfigChanged = onConfigChanged
        model.setDisablePhysical = setDisablePhysical
        model.start()
        self.model = model
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "UU远程分辨率伴侣 设置"
        w.contentView = NSHostingView(rootView: SettingsView(model: model, openPermissions: openPermissions))
        w.isReleasedWhenClosed = false
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

    /// 调试：把两个面板渲染成 PNG（--render-settings <目录>）
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, pane, physical, watchdog) in [("devices", SettingsPane.devices, false, false),
                                                  ("displays-off", .displays, false, false),
                                                  ("displays-on", .displays, true, false),
                                                  ("displays-watchdog", .displays, true, true)] {
            let model = SettingsModel()
            model.pane = pane
            model.disablePhysical = physical
            model.watchdogEnabled = watchdog
            model.watchdogRunning = false
            let view = NSHostingView(rootView: SettingsView(model: model).frame(width: 1040, height: physical ? 1180 : 640))
            view.frame = NSRect(x: 0, y: 0, width: 1040, height: physical ? 1180 : 640)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("settings-\(name).png"))
            }
        }
    }
}
