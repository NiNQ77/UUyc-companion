// 「关于」窗口里本软件自己的信息（作者信息与 Debug 编号开关由 AboutKit 提供）
import AboutKit
import AppKit

enum AboutPage {
    private static let controller = AboutWindowController(app: AboutApp(
        name: "UU远程伴侣",
        summary: "改善 Mac 版 UU远程 的使用体验，自动提供与您的设备同分辨率的虚拟屏幕，告别上下大黑边。",
        repository: "https://github.com/aoyamashou/UUyc-companion",
        credits: [
            OpenSourceCredit(name: "FreeDisplay", url: "https://github.com/huberdf/FreeDisplay",
                             author: "huberdf", license: "MIT", usage: "虚拟屏接口声明"),
            OpenSourceCredit(name: "PermissionFlow", url: "https://github.com/jaywcjlove/PermissionFlow",
                             author: "小弟调调（jaywcjlove）", license: "MIT", usage: "授权引导"),
            OpenSourceCredit(name: "TourKit", url: "https://github.com/rampatra/TourKit",
                             author: "Ram Patra（rampatra）", license: "MIT", usage: "功能介绍页"),
        ],
        disclaimer: "本应用与 UU远程 及其开发商没有任何直接、间接或连带关系，仅为作者自己使用方便而开发。如果将来 UU远程 官方在 Mac 版中内置了同样的功能，删掉本应用即可。"
    ))

    static func show() { controller.show() }

    /// 调试：渲染为 PNG（--render-about <文件>）
    static func render(to url: URL) { controller.render(to: url) }

    /// Debug 编号：对照表放在配置目录，按窗口加前缀（S 设置、P 权限、T 功能介绍）
    static func setUpDebugLabels() {
        DebugLabels.fileURL = ConfigStore.dir.appendingPathComponent("ui-labels.txt")
        DebugLabels.windowPrefix = { w in
            if w.className.contains("TourKit") { return "T" }
            if w.title.contains("权限") || w.title.contains("授权") { return "P" }
            if w.title.contains("设置") { return "S" }
            return nil
        }
        DebugLabels.start()
    }
}
