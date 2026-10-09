// 看门狗：由 launchd 托管（KeepAlive）的独立进程，兜底恢复被禁用的物理屏
// 触发条件（存在禁用记录时）：主程序不在 / 心跳超时（卡死，先强杀再恢复）/ UU 已断开 5 秒
import CoreGraphics
import Foundation
import ServiceManagement

enum Heartbeat {
    static let appURL = ConfigStore.dir.appendingPathComponent("heartbeat-app")
    static let watchdogURL = ConfigStore.dir.appendingPathComponent("heartbeat-watchdog")

    static func beat(_ url: URL) {
        try? "\(getpid())".write(to: url, atomically: true, encoding: .utf8)
    }

    /// (pid, 距上次心跳秒数)
    static func read(_ url: URL) -> (pid: pid_t, age: TimeInterval)? {
        guard let s = try? String(contentsOf: url, encoding: .utf8), let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return nil }
        return (pid, Date().timeIntervalSince(m))
    }

    static func alive(_ url: URL, maxAge: TimeInterval) -> Bool {
        guard let hb = read(url) else { return false }
        return kill(hb.pid, 0) == 0 && hb.age < maxAge
    }
}

enum Watchdog {
    static let label = "com.corndog.uudisplay.watchdog"
    static var service: SMAppService { .agent(plistName: "\(label).plist") }
    static let appMaxAge: TimeInterval = 10
    static let uuGoneLimit: TimeInterval = 5

    /// 主程序只在看门狗健在时才禁用物理屏
    static var isRunning: Bool { Heartbeat.alive(Heartbeat.watchdogURL, maxAge: 5) }

    private static let assumeUU = ProcessInfo.processInfo.environment["UUDISPLAY_WATCHDOG_ASSUME_UU"] == "1"

    static func run() -> Never {
        try? FileManager.default.createDirectory(at: ConfigStore.dir, withIntermediateDirectories: true)
        Log.info("[看门狗] 启动 pid=\(getpid())")
        var uuGoneSince: Date?
        while true {
            autoreleasepool {
                Heartbeat.beat(Heartbeat.watchdogURL)
                guard PhysicalDisplays.pending != nil else { uuGoneSince = nil; return }

                let hb = Heartbeat.read(Heartbeat.appURL)
                let appExists = hb.map { kill($0.pid, 0) == 0 } ?? false
                let appHealthy = appExists && (hb?.age ?? .infinity) < appMaxAge
                // 测试开关：假定 UU 一直连着，用于单独验证心跳超时
                let uu = assumeUU || UUMonitor.overlayPresent()
                uuGoneSince = uu ? nil : (uuGoneSince ?? Date())

                if !appHealthy {
                    if appExists, let pid = hb?.pid {
                        Log.info("[看门狗] 主程序心跳超时 \(Int(hb?.age ?? 0)) 秒，强制结束 pid=\(pid)")
                        kill(pid, SIGKILL)
                    }
                    PhysicalDisplays.restore(reason: "看门狗：主程序\(appExists ? "卡死" : "不在")")
                } else if let t = uuGoneSince, Date().timeIntervalSince(t) > uuGoneLimit {
                    PhysicalDisplays.restore(reason: "看门狗：UU 已断开但物理屏未恢复")
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }
}
