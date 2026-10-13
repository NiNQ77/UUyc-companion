// 调试：给界面元素标编号，方便口头指认（「关于」窗口里的 Debug 按钮开关）
// 不改各界面代码：遍历本进程窗口的辅助功能树，在窗口上方盖一层透明子窗口画编号；
// 菜单项则在标题前加编号。编号对照表写到 ~/Library/Application Support/UUDisplay/ui-labels.txt
import AppKit

enum DebugLabels {
    private static let key = "debugLabels"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            newValue ? start() : stop()
        }
    }

    static let fileURL = ConfigStore.dir.appendingPathComponent("ui-labels.txt")

    private static var timer: Timer?
    private static var overlays: [ObjectIdentifier: OverlayWindow] = [:]
    private static var menuLines: [String] = []
    private static var lastDump = ""

    static func start() {
        guard enabled, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in refresh() }
        refresh()
    }

    static func stop() {
        timer?.invalidate()
        timer = nil
        overlays.values.forEach { $0.parent?.removeChildWindow($0); $0.orderOut(nil) }
        overlays.removeAll()
    }

    // MARK: 菜单：标题前加 M1、M2…

    static func decorate(_ menu: NSMenu) {
        guard enabled else { return }
        menuLines = []
        var n = 0
        func walk(_ m: NSMenu, _ path: String) {
            for it in m.items where !it.isSeparatorItem {
                n += 1
                let tag = "M\(n)"
                menuLines.append("\(tag)\t菜单项\t「\(path)\(it.title)」")
                it.title = "\(tag) \(it.title)"
                if let sub = it.submenu { walk(sub, "\(path)\(it.title) › ") }
            }
        }
        walk(menu, "")
        writeDump()
    }

    // MARK: 窗口

    private struct Item { let frame: NSRect; let tag: String; let line: String }

    private static let roles: Set<NSAccessibility.Role> = [
        .staticText, .button, .checkBox, .radioButton, .popUpButton, .menuButton, .textField, .textArea,
        .comboBox, .image, .slider, .link, .disclosureTriangle, .radioGroup, .incrementor, .tabGroup,
    ]

    /// 窗口前缀：S 设置、P 权限、T 功能介绍、A 关于，其余按出现顺序 W1-、W2-…（带短横线，免得和序号连在一起）
    private static func prefix(for w: NSWindow, index: Int) -> String {
        let t = w.title
        if t.hasPrefix("关于") { return "A" }
        if w.className.contains("TourKit") { return "T" }
        if t.contains("权限") || t.contains("授权") { return "P" }
        if t.contains("设置") { return "S" }
        return "W\(index)-"
    }

    private static func refresh() {
        var lines: [String] = []
        var alive = Set<ObjectIdentifier>()
        let windows = NSApp.windows.filter {
            !($0 is OverlayWindow) && $0.isVisible && $0.frame.width > 80 && $0.frame.height > 60
                && !$0.className.contains("StatusBar") && !$0.className.contains("Menu")
        }
        for (i, w) in windows.enumerated() {
            let p = prefix(for: w, index: i + 1)
            var items: [Item] = []
            var n = 0
            // SwiftUI 的节点（AccessibilityNode）实现了这些方法但没声明协议，统一用动态调用
            // clip：滚动区域的可见范围，滚出视野的元素不标
            func walk(_ obj: Any, depth: Int, clip: NSRect) {
                guard depth < 40 else { return }
                let e = obj as AnyObject
                let role = e.accessibilityRole?() ?? nil
                let frame = e.accessibilityFrame?() ?? .zero
                if let role, roles.contains(role), frame.width > 1, frame.height > 1, clip.intersects(frame) {
                    n += 1
                    let tag = "\(p)\(n)"
                    let value = (e as? NSObject)?.value(forKey: "accessibilityValue") as? String
                    let text = [e.accessibilityTitle?() ?? nil, e.accessibilityLabel?() ?? nil, value]
                        .compactMap { $0 }.filter { !$0.isEmpty }.first ?? ""
                    items.append(Item(frame: frame, tag: tag,
                                      line: "\(tag)\t\(role.rawValue.replacingOccurrences(of: "AX", with: ""))\t「\(text)」"))
                }
                let inner = role == .scrollArea ? clip.intersection(frame) : clip
                for c in (e.accessibilityChildren?() ?? nil) ?? [] { walk(c, depth: depth + 1, clip: inner) }
            }
            walk(w, depth: 0, clip: w.frame)
            lines.append("== \(p)：\(w.title.isEmpty ? w.className : w.title)")
            lines += items.map(\.line)

            let id = ObjectIdentifier(w)
            alive.insert(id)
            let ov = overlays[id] ?? {
                let o = OverlayWindow(parentWindow: w)
                overlays[id] = o
                return o
            }()
            ov.update(items: items.map { ($0.frame, $0.tag) })
        }
        for (id, ov) in overlays where !alive.contains(id) {
            ov.parent?.removeChildWindow(ov); ov.orderOut(nil)
            overlays[id] = nil
        }
        lastWindowLines = lines
        writeDump()
    }

    private static var lastWindowLines: [String] = []

    private static func writeDump() {
        let text = (lastWindowLines + ["== M：菜单栏菜单（打开过菜单后才有）"] + menuLines).joined(separator: "\n") + "\n"
        guard text != lastDump else { return }
        lastDump = text
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

/// 盖在目标窗口上方的透明子窗口，只画编号，不接收鼠标
private final class OverlayWindow: NSWindow {
    private let canvas = OverlayView()

    init(parentWindow: NSWindow) {
        super.init(contentRect: parentWindow.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = canvas
        parentWindow.addChildWindow(self, ordered: .above)
    }

    func update(items: [(NSRect, String)]) {
        guard let p = parent else { return }
        if frame != p.frame { setFrame(p.frame, display: false) }
        // 屏幕坐标 → 本窗口坐标
        canvas.items = items.map { (NSRect(x: $0.0.minX - p.frame.minX, y: $0.0.minY - p.frame.minY,
                                           width: $0.0.width, height: $0.0.height), $0.1) }
    }
}

private final class OverlayView: NSView {
    var items: [(NSRect, String)] = [] {
        didSet { if !items.elementsEqual(oldValue, by: { $0.0 == $1.0 && $0.1 == $1.1 }) { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        for (r, tag) in items {
            NSColor.systemRed.withAlphaComponent(0.35).setStroke()
            let outline = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
            let s = NSAttributedString(string: tag, attributes: attrs)
            let size = s.size()
            // 编号牌贴在元素左上角外侧，不遮挡文字
            let badge = NSRect(x: r.minX - 2, y: min(r.maxY - 1, bounds.maxY - size.height - 2),
                               width: size.width + 6, height: size.height + 2)
            NSColor.systemRed.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            s.draw(at: NSPoint(x: badge.minX + 3, y: badge.minY + 1))
        }
    }
}
