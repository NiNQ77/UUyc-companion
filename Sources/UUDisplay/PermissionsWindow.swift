// 权限设置窗口：用 PermissionFlow 引导授权（打开系统设置隐私页 + 拖拽授权悬浮面板），状态实时刷新
import AppKit
import PermissionFlow
import ServiceManagement
import SwiftUI
import SystemSettingsKit

final class PermissionsModel: ObservableObject {
    @Published var axGranted = UUReader.isTrusted
    @Published var watchdogStatus = Watchdog.service.status
    /// 由未全部授权变为全部授权时回调
    var onAllGranted: (() -> Void)?
    private var timer: Timer?

    /// 非 .app 运行（开发调试）时看门狗无法注册，不作要求
    static var isBundled: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    var watchdogOK: Bool { !PermissionsModel.isBundled || watchdogStatus == .enabled }
    var allGranted: Bool { axGranted && watchdogOK }

    static var allGranted: Bool {
        UUReader.isTrusted && (!isBundled || Watchdog.service.status == .enabled)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate() }

    func refresh() {
        let before = allGranted
        defer { if !before && allGranted { onAllGranted?() } }
        let ax = UUReader.isTrusted
        let wd = Watchdog.service.status
        if ax != axGranted { axGranted = ax; Log.info("辅助功能权限：\(ax ? "已授权" : "未授权")") }
        if wd != watchdogStatus { watchdogStatus = wd; Log.info("看门狗状态：\(wd.rawValue)") }
    }

    @MainActor func enableWatchdog() {
        do { try Watchdog.service.register() } catch { Log.info("⚠️ 看门狗注册失败：\(error.localizedDescription)") }
        refresh()
        if watchdogStatus == .requiresApproval { SystemSettings.open(.loginItems) }
    }
}

private struct StatusBadge: View {
    let ok: Bool
    let okText: String
    let pendingText: String

    var body: some View {
        Label(ok ? okText : pendingText, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(ok ? .green : .orange)
            .font(.callout.weight(.medium))
    }
}

private struct PermissionCard<Action: View>: View {
    let icon: String
    let title: Text
    let tag: String
    let detail: String
    let ok: Bool
    let okText: String
    let pendingText: String
    var tip: String?
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    title.font(.headline)
                    Text(tag).font(.caption).foregroundStyle(.secondary)
                }
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !ok, let tip {
                    Text(tip).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                StatusBadge(ok: ok, okText: okText, pendingText: pendingText)
                if !ok { action() }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct PermissionsView: View {
    @ObservedObject var model: PermissionsModel
    var onDone: () -> Void

    private var appURL: URL { Bundle.main.bundleURL }

    private var watchdogPending: String {
        switch model.watchdogStatus {
        case .requiresApproval: return "需在登录项中允许"
        case .notFound: return "未找到"
        default: return "未启用"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("授权 UU远程分辨率伴侣").font(.title2.bold())
                Text("完成下面的授权后，平板或手机连入时才能自动识别设备并切换分辨率。")
                    .foregroundStyle(.secondary)
            }

            PermissionCard(
                icon: "hand.raised.fill",
                // macOS 27 起叫「设备控制和数据访问」，更早为「辅助功能」；固定取简体中文
                title: Text(PermissionFlowResources.localizedString(
                    for: PermissionFlowResources.accessibilityName(), localeIdentifier: "zh-Hans")),
                tag: "必需",
                detail: "读取 UU远程 的设备列表，识别是哪台设备连进来。",
                ok: model.axGranted,
                okText: "已授权",
                pendingText: "未授权",
                tip: "点「授权」会打开系统设置，并在旁边出现一个小面板，把面板里的 UUDisplay 拖进列表即可。\n升级后如果列表里已有 UUDisplay 却仍显示未授权：先选中它点「−」删除，再重新拖入。"
            ) {
                PermissionFlowButton(
                    pane: .accessibility,
                    suggestedAppURLs: [appURL],
                    configuration: .init(requiredAppURLs: [appURL], promptForAccessibilityTrust: false, localeIdentifier: "zh-Hans")
                ) { _ in
                    // 状态由左侧徽标统一显示，按钮只负责发起授权
                    Label("授权", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.borderedProminent)
            }

            if PermissionsModel.isBundled {
                PermissionCard(
                    icon: "shield.lefthalf.filled",
                    title: Text("后台看门狗"),
                    tag: "推荐",
                    detail: "远程时关闭物理屏的兜底保护：主程序异常时自动恢复屏幕。需要允许 UUDisplay 在后台运行。",
                    ok: model.watchdogOK,
                    okText: "已开启",
                    pendingText: watchdogPending,
                    tip: "未开启时，远程期间不会关闭物理屏，其余功能不受影响。"
                ) {
                    Button(model.watchdogStatus == .requiresApproval ? "打开登录项" : "启用") { model.enableWatchdog() }
                        .buttonStyle(.borderedProminent)
                }
            }

            HStack {
                if model.allGranted {
                    Label("全部就绪", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
                Spacer()
                if model.allGranted {
                    Button("完成", action: onDone).keyboardShortcut(.defaultAction)
                } else {
                    Button("稍后再说", action: onDone)
                }
            }
        }
        .padding(22)
        .frame(width: 620)
    }
}

final class PermissionsWindowController {
    private var window: NSWindow?
    private var model: PermissionsModel?
    private var onDone: (() -> Void)?

    var isVisible: Bool { window != nil }

    /// - Parameter autoClose: 全部授权后自动关闭（首次启动引导时使用）
    func show(autoClose: Bool = false, onDone: (() -> Void)? = nil) {
        if let onDone { self.onDone = onDone }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = PermissionsModel()
        model.start()
        self.model = model
        let view = PermissionsView(model: model) { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "权限设置"
        w.contentView = hosting
        w.isReleasedWhenClosed = false
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.finish()
        }
        if autoClose {
            model.onAllGranted = { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.close() }
            }
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }

    private func finish() {
        model?.stop()
        model = nil
        window = nil
        let done = onDone
        onDone = nil
        done?()
    }
}
