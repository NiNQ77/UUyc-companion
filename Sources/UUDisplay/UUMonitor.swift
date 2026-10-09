// 监听 UU 被控状态：UURemoteServer 被控时会在各屏铺覆盖窗口（CGWindowList 可见，无需权限）
import CoreGraphics
import Foundation

final class UUMonitor {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    private(set) var connected = false

    private var timer: Timer?
    private var lastSeen = Date.distantPast
    /// 切换主屏时覆盖窗口会短暂重建，断开需持续缺席这么久才算数
    private let debounce: TimeInterval = 1.5

    static func overlayPresent() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowOwnerName as String] as? String) == "UURemoteServer" }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    private func tick() {
        let now = Date()
        if UUMonitor.overlayPresent() {
            lastSeen = now
            if !connected {
                connected = true
                Log.info("检测到 UU 连入")
                onConnect?()
            }
        } else if connected, now.timeIntervalSince(lastSeen) > debounce {
            connected = false
            Log.info("检测到 UU 断开")
            onDisconnect?()
        }
    }
}
