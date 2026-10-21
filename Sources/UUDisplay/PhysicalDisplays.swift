// 远程期间将物理屏镜像到虚拟屏（避免停用物理屏导致音频流中断，同时避免窗口和 Dock 跑丢）及其兜底恢复
import CoreGraphics
import Foundation

/// 同步执行一次显示器配置事务。GUI 进程中不可在主线程调用（会与自身重配置通知死锁）
@discardableResult
func applyDisplayConfig(_ body: (CGDisplayConfigRef?) -> Void) -> CGError {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success else { return .failure }
    body(cfg)
    let err = CGCompleteDisplayConfiguration(cfg, .forSession)
    if err != .success { CGCancelDisplayConfiguration(cfg) }
    return err
}

enum PhysicalDisplays {
    private typealias EnableFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private static let setEnabled: EnableFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled")
        .map { unsafeBitCast($0, to: EnableFn.self) }

    /// CGConfigureDisplayMirrorOfDisplay 为公有 API，始终可用
    static var available: Bool { true }

    /// 已被镜像/待恢复的物理屏记录
    static let markerURL = ConfigStore.dir.appendingPathComponent("disabled-displays.json")

    static var pending: [CGDirectDisplayID]? {
        guard let data = try? Data(contentsOf: markerURL),
              let ids = try? JSONDecoder().decode([CGDirectDisplayID].self, from: data), !ids.isEmpty else { return nil }
        return ids
    }

    /// 先记账再镜像。须在后台队列调用。
    /// 将物理屏设置为虚拟屏的镜像：物理屏保持在线（音频流不崩溃），同时桌面合一（窗口不跑丢）
    static func mirror(_ ids: [CGDirectDisplayID], to masterID: CGDirectDisplayID) -> CGError {
        guard !ids.isEmpty else { return .failure }
        let merged = Array(Set((pending ?? []) + ids))
        guard (try? JSONEncoder().encode(merged).write(to: markerURL, options: .atomic)) != nil else {
            Log.info("❌ 无法写入物理屏记录，放弃镜像")
            return .failure
        }
        return applyDisplayConfig { cfg in
            ids.forEach { CGConfigureDisplayMirrorOfDisplay(cfg, $0, masterID) }
        }
    }

    /// 兼容旧方法
    static func disable(_ ids: [CGDirectDisplayID]) -> CGError {
        if let master = CGMainDisplayID() as CGDirectDisplayID?, master != 0 {
            return mirror(ids, to: master)
        }
        guard let setEnabled, !ids.isEmpty else { return .failure }
        let merged = Array(Set((pending ?? []) + ids))
        _ = try? JSONEncoder().encode(merged).write(to: markerURL, options: .atomic)
        return applyDisplayConfig { cfg in ids.forEach { _ = setEnabled(cfg, $0, false) } }
    }

    /// 按记录解除镜像并恢复物理屏；成功后删除记录。可在任意进程调用，重复调用无害
    @discardableResult
    static func restore(reason: String) -> Bool {
        guard let ids = pending else { return true }
        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onlineCount)
        var onlineIds = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
        CGGetOnlineDisplayList(onlineCount, &onlineIds, &onlineCount)
        let onlineSet = Set(onlineIds)

        let mirroringIds = ids.filter { onlineSet.contains($0) && CGDisplayMirrorsDisplay($0) != kCGNullDirectDisplay }
        let disabledIds = ids.filter { !onlineSet.contains($0) }

        if !mirroringIds.isEmpty || !disabledIds.isEmpty {
            let err = applyDisplayConfig { cfg in
                mirroringIds.forEach {
                    CGConfigureDisplayMirrorOfDisplay(cfg, $0, kCGNullDirectDisplay)
                }
                if let setEnabled {
                    disabledIds.forEach {
                        _ = setEnabled(cfg, $0, true)
                    }
                }
            }
            if err != .success {
                Log.info("⚠️ 恢复物理屏失败 CGError=\(err.rawValue)（\(reason)），稍后重试")
                return false
            }
        }
        try? FileManager.default.removeItem(at: markerURL)
        Log.info("✅ 已恢复物理屏（解除镜像）\(ids)（\(reason)）")
        return true
    }
}
