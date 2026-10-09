// 虚拟屏生命周期：创建 → 设为主屏 → 还原布局 → 释放
// 要点：创建时只给一个模式且之后不改（改过模式的虚拟屏可能无法移除）；
//      释放 CGVirtualDisplay 对象即移除虚拟屏，进程退出/崩溃时系统也会自动移除；
//      GUI 进程主线程调用 CGCompleteDisplayConfiguration 会卡死，布局修改统一放到串行后台队列。
import CGVirtualDisplayBridge
import CoreGraphics
import Foundation

final class DisplayManager {
    private var vd: CGVirtualDisplay?
    private(set) var current: DeviceConfig?
    /// 建屏前各物理屏的原点，用于还原
    private var savedOrigins: [CGDirectDisplayID: CGPoint] = [:]
    private var pendingMain: DispatchWorkItem?
    private let cgQueue = DispatchQueue(label: "uudisplay.display-config")

    private static let markerURL = ConfigStore.dir.appendingPathComponent("session.json")

    var isActive: Bool { vd != nil }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// 已是同规格虚拟屏则不动
    func matches(_ cfg: DeviceConfig) -> Bool {
        guard let c = current, vd != nil else { return false }
        return c.width == cfg.width && c.height == cfg.height && c.hiDPI == cfg.hiDPI
    }

    @discardableResult
    func create(_ cfg: DeviceConfig) -> Bool {
        remove()
        let w = cfg.width, h = cfg.height
        let desc = CGVirtualDisplayDescriptor()
        desc.name = "UUDisplay · \(cfg.name)"
        desc.maxPixelsWide = UInt32(w)
        desc.maxPixelsHigh = UInt32(h)
        desc.sizeInMillimeters = CGSize(width: Double(w) / 220 * 25.4, height: Double(h) / 220 * 25.4)
        desc.vendorID = 0x5555
        desc.productID = 0x0001
        // 每次随机序列号：与残留虚拟屏同序列号时 CGVirtualDisplay 会返回 nil
        desc.serialNum = UInt32.random(in: 1...0xFFFF_FFF0)

        let created: CGVirtualDisplay? = autoreleasepool { CGVirtualDisplay(descriptor: desc) }
        guard let display = created else {
            Log.info("❌ 创建虚拟屏失败（CGVirtualDisplay 返回 nil）")
            return false
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = cfg.hiDPI
        let mw = cfg.hiDPI ? w / 2 : w, mh = cfg.hiDPI ? h / 2 : h
        settings.modes = [CGVirtualDisplayMode(width: UInt(mw), height: UInt(mh), refreshRate: 60)]
        guard autoreleasepool(invoking: { display.apply(settings) }) else {
            Log.info("❌ 虚拟屏 applySettings 失败")
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
            self.savedOrigins = Dictionary(uniqueKeysWithValues: online.filter { $0 != id }.map { ($0, CGDisplayBounds($0).origin) })
            self.writeMarker()
            self.cgQueue.async {
                let err = DisplayManager.configure { cfg in
                    let t = CGDisplayBounds(id).origin
                    for d in online {
                        let o = CGDisplayBounds(d).origin
                        CGConfigureDisplayOrigin(cfg, d, Int32(o.x - t.x), Int32(o.y - t.y))
                    }
                }
                Log.info(err == .success ? "✅ 虚拟屏已设为主屏" : "⚠️ 设主屏失败 CGError=\(err.rawValue)")
            }
        }
        pendingMain = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 先释放虚拟屏（系统会自动把主屏交还物理屏），再在后台把物理屏原点还原
    /// - Parameter wait: 退出时同步等待还原完成（最多 3 秒）
    func remove(wait: Bool = false) {
        pendingMain?.cancel()
        pendingMain = nil
        guard let display = vd else { return }
        let id = display.displayID
        autoreleasepool { vd = nil }
        Log.info("✅ 已移除虚拟屏 #\(id)")
        current = nil
        let origins = savedOrigins
        savedOrigins = [:]
        try? FileManager.default.removeItem(at: DisplayManager.markerURL)
        let done = DispatchSemaphore(value: 0)
        cgQueue.asyncAfter(deadline: .now() + 0.5) {
            DisplayManager.restoreOrigins(origins)
            done.signal()
        }
        if wait { _ = done.wait(timeout: .now() + 3) }
    }

    private static func configure(_ body: (CGDisplayConfigRef?) -> Void) -> CGError {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return .failure }
        body(cfg)
        let err = CGCompleteDisplayConfiguration(cfg, .forSession)
        if err != .success { CGCancelDisplayConfiguration(cfg) }
        return err
    }

    private static func restoreOrigins(_ origins: [CGDirectDisplayID: CGPoint]) {
        let online = Set(onlineDisplays())
        let targets = origins.filter { online.contains($0.key) }
        guard !targets.isEmpty else { return }
        let err = configure { cfg in
            for (id, o) in targets { CGConfigureDisplayOrigin(cfg, id, Int32(o.x), Int32(o.y)) }
        }
        Log.info(err == .success ? "✅ 已还原显示器布局" : "⚠️ 还原布局 CGError=\(err.rawValue)")
    }

    // MARK: - 异常退出后的恢复

    private func writeMarker() {
        let dict = Dictionary(uniqueKeysWithValues: savedOrigins.map { ("\($0.key)", [$0.value.x, $0.value.y]) })
        try? JSONSerialization.data(withJSONObject: dict).write(to: DisplayManager.markerURL, options: .atomic)
    }

    /// 上次运行时虚拟屏未正常移除（崩溃/强退）：虚拟屏已随进程消失，这里把物理屏布局还原
    func recoverIfNeeded() {
        guard let data = try? Data(contentsOf: DisplayManager.markerURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] else { return }
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        for (k, v) in dict where v.count == 2 {
            if let id = UInt32(k) { origins[id] = CGPoint(x: v[0], y: v[1]) }
        }
        Log.info("发现上次异常退出的残留状态，恢复显示器布局")
        cgQueue.async { DisplayManager.restoreOrigins(origins) }
        try? FileManager.default.removeItem(at: DisplayManager.markerURL)
    }
}
