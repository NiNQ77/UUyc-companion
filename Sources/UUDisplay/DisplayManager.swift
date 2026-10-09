// 虚拟屏生命周期：创建 → 设为主屏 →（可选）禁用物理屏 → 恢复物理屏 → 释放 → 还原布局
// 要点：创建时只给一个模式且之后不改（改过模式的虚拟屏可能无法移除）；
//      释放 CGVirtualDisplay 对象即移除虚拟屏，进程退出/崩溃时系统也会自动移除；
//      GUI 进程主线程调用 CGCompleteDisplayConfiguration 会卡死，布局修改统一放到串行后台队列；
//      换设备时新屏成为主屏后再释放旧屏，期间物理屏保持禁用，避免出现「无屏」状态。
import CGVirtualDisplayBridge
import CoreGraphics
import Foundation

final class DisplayManager {
    static let vendorID: UInt32 = 0x5555

    private var vd: CGVirtualDisplay?
    /// 换设备时的旧屏，等新屏成为主屏后释放
    private var retiring: [CGVirtualDisplay] = []
    private(set) var current: DeviceConfig?
    /// 建屏前各物理屏的原点，用于还原
    private var savedOrigins: [CGDirectDisplayID: CGPoint] = [:]
    private var pendingMain: DispatchWorkItem?
    private let cgQueue = DispatchQueue(label: "uudisplay.display-config")

    /// 是否应禁用物理屏（由 Coordinator 按设置与看门狗状态决定）
    var shouldDisablePhysical: () -> Bool = { false }
    /// 物理屏当前是否被本程序禁用
    private(set) var physicalOff = false
    /// 用户手动恢复后，本次连接内不再禁用
    private var physicalOverride = false

    private static let markerURL = ConfigStore.dir.appendingPathComponent("session.json")

    var isActive: Bool { vd != nil }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool { CGDisplayVendorNumber(id) == vendorID }

    /// 已是同规格虚拟屏则不动
    func matches(_ cfg: DeviceConfig) -> Bool {
        guard let c = current, vd != nil else { return false }
        return c.width == cfg.width && c.height == cfg.height && c.hiDPI == cfg.hiDPI
    }

    @discardableResult
    func create(_ cfg: DeviceConfig) -> Bool {
        pendingMain?.cancel()
        if let old = vd { retiring.append(old) }
        vd = nil
        current = nil

        let w = cfg.width, h = cfg.height
        let desc = CGVirtualDisplayDescriptor()
        desc.name = "UUDisplay · \(cfg.name)"
        desc.maxPixelsWide = UInt32(w)
        desc.maxPixelsHigh = UInt32(h)
        desc.sizeInMillimeters = CGSize(width: Double(w) / 220 * 25.4, height: Double(h) / 220 * 25.4)
        desc.vendorID = DisplayManager.vendorID
        desc.productID = 0x0001
        // 每次随机序列号：与残留虚拟屏同序列号时 CGVirtualDisplay 会返回 nil
        desc.serialNum = UInt32.random(in: 1...0xFFFF_FFF0)

        let created: CGVirtualDisplay? = autoreleasepool { CGVirtualDisplay(descriptor: desc) }
        guard let display = created else {
            Log.info("❌ 创建虚拟屏失败（CGVirtualDisplay 返回 nil）")
            remove()
            return false
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = cfg.hiDPI
        let mw = cfg.hiDPI ? w / 2 : w, mh = cfg.hiDPI ? h / 2 : h
        settings.modes = [CGVirtualDisplayMode(width: UInt(mw), height: UInt(mh), refreshRate: 60)]
        guard autoreleasepool(invoking: { display.apply(settings) }) else {
            Log.info("❌ 虚拟屏 applySettings 失败")
            remove()
            return false
        }
        vd = display
        current = cfg
        Log.info("✅ 已创建虚拟屏 #\(display.displayID) \(cfg.name) \(cfg.sizeLabel)")
        scheduleMakeMain(display.displayID, attempt: 0)
        return true
    }

    /// 虚拟屏上线是异步的，等它出现在显示器列表后再设为主屏
    private func scheduleMakeMain(_ id: CGDirectDisplayID, attempt: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.vd?.displayID == id else { return }
            let online = DisplayManager.onlineDisplays()
            guard online.contains(id) else {
                if attempt < 20 { self.scheduleMakeMain(id, attempt: attempt + 1) }
                else { Log.info("⚠️ 虚拟屏 5 秒内未上线") }
                return
            }
            if self.savedOrigins.isEmpty {
                self.savedOrigins = Dictionary(uniqueKeysWithValues: online.filter { !DisplayManager.isVirtual($0) }
                    .map { ($0, CGDisplayBounds($0).origin) })
            }
            self.writeMarker()
            let retire = self.retiring
            self.retiring = []
            self.cgQueue.async {
                let err = applyDisplayConfig { cfg in
                    let t = CGDisplayBounds(id).origin
                    for d in online {
                        let o = CGDisplayBounds(d).origin
                        CGConfigureDisplayOrigin(cfg, d, Int32(o.x - t.x), Int32(o.y - t.y))
                    }
                }
                Log.info(err == .success ? "✅ 虚拟屏已设为主屏" : "⚠️ 设主屏失败 CGError=\(err.rawValue)")
                DispatchQueue.main.async {
                    self.release(retire)
                    self.disablePhysicalIfNeeded()
                }
            }
        }
        pendingMain = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func release(_ displays: [CGVirtualDisplay]) {
        guard !displays.isEmpty else { return }
        // 最后一个引用随调用方闭包释放后虚拟屏即消失
        let ids = displays.map(\.displayID)
        Log.info("✅ 已移除虚拟屏 \(ids.map { "#\($0)" }.joined(separator: " "))")
    }

    // MARK: - 物理屏

    func disablePhysicalIfNeeded() {
        guard let id = vd?.displayID, !physicalOff, !physicalOverride, shouldDisablePhysical() else { return }
        let physical = DisplayManager.onlineDisplays().filter { !DisplayManager.isVirtual($0) }
        guard !physical.isEmpty else { return }
        physicalOff = true
        cgQueue.async {
            let err = PhysicalDisplays.disable(physical)
            Log.info(err == .success ? "✅ 已关闭物理屏 \(physical)，只保留虚拟屏 #\(id)" : "⚠️ 关闭物理屏失败 CGError=\(err.rawValue)")
            if err != .success { DispatchQueue.main.async { self.physicalOff = false } }
        }
    }

    /// 快捷键 / 菜单 / 关闭开关：立即恢复物理屏，虚拟屏保留；本次连接内不再禁用
    func restorePhysicalNow(override: Bool = true) {
        if override { physicalOverride = true }
        guard physicalOff || PhysicalDisplays.pending != nil else { return }
        physicalOff = false
        cgQueue.async { PhysicalDisplays.restore(reason: "手动恢复") }
    }

    // MARK: - 移除

    /// 顺序：恢复物理屏 → 释放虚拟屏（系统把主屏交还物理屏）→ 还原物理屏原点
    func remove(completion: (() -> Void)? = nil) {
        pendingMain?.cancel()
        pendingMain = nil
        let displays = retiring + [vd].compactMap { $0 }
        retiring = []
        vd = nil
        current = nil
        physicalOverride = false
        let wasOff = physicalOff
        physicalOff = false
        let origins = savedOrigins
        savedOrigins = [:]
        guard !displays.isEmpty || wasOff else { completion?(); return }

        cgQueue.async {
            if wasOff || PhysicalDisplays.pending != nil { PhysicalDisplays.restore(reason: "远程结束") }
            DispatchQueue.main.async {
                self.release(displays)
                try? FileManager.default.removeItem(at: DisplayManager.markerURL)
                self.cgQueue.asyncAfter(deadline: .now() + 0.5) {
                    DisplayManager.restoreOrigins(origins)
                    if let completion { DispatchQueue.main.async(execute: completion) }
                }
            }
        }
    }

    private static func restoreOrigins(_ origins: [CGDirectDisplayID: CGPoint]) {
        let online = Set(onlineDisplays())
        let targets = origins.filter { online.contains($0.key) }
        guard !targets.isEmpty else { return }
        let err = applyDisplayConfig { cfg in
            for (id, o) in targets { CGConfigureDisplayOrigin(cfg, id, Int32(o.x), Int32(o.y)) }
        }
        Log.info(err == .success ? "✅ 已还原显示器布局" : "⚠️ 还原布局 CGError=\(err.rawValue)")
    }

    // MARK: - 异常退出后的恢复

    private func writeMarker() {
        let dict = Dictionary(uniqueKeysWithValues: savedOrigins.map { ("\($0.key)", [$0.value.x, $0.value.y]) })
        try? JSONSerialization.data(withJSONObject: dict).write(to: DisplayManager.markerURL, options: .atomic)
    }

    /// 上次运行时未正常收尾（崩溃/强退）：虚拟屏已随进程消失，这里恢复物理屏并还原布局
    func recoverIfNeeded() {
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        if let data = try? Data(contentsOf: DisplayManager.markerURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] {
            for (k, v) in dict where v.count == 2 {
                if let id = UInt32(k) { origins[id] = CGPoint(x: v[0], y: v[1]) }
            }
        }
        guard !origins.isEmpty || PhysicalDisplays.pending != nil else { return }
        Log.info("发现上次异常退出的残留状态，恢复物理屏与显示器布局")
        try? FileManager.default.removeItem(at: DisplayManager.markerURL)
        cgQueue.async {
            PhysicalDisplays.restore(reason: "启动时恢复")
            DisplayManager.restoreOrigins(origins)
        }
    }
}
