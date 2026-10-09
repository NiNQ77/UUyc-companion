// 首次启动 / 重新配置向导：读取 UU 设备列表，确认类型与分辨率
import AppKit
import SwiftUI

final class WizardModel: ObservableObject {
    @Published var rows: [DeviceConfig] = []
    @Published var defaultDevice: String = ""
    @Published var message: String?
    @Published var trusted = UUReader.isTrusted
    @Published var newName = ""

    private let store = ConfigStore.shared

    init() { load() }

    func load() {
        trusted = UUReader.isTrusted
        guard trusted else {
            message = "需要「辅助功能」权限才能读取 UU 设备列表。授权后点「重新读取」。"
            rows = store.config.devices
            defaultDevice = store.config.defaultDevice ?? ""
            return
        }
        if !UUReader.hasMainWindow { UUReader.showMainWindow(); Thread.sleep(forTimeInterval: 1) }
        let found = (UUReader.readDevices() ?? []).filter { !$0.isSelf }
        // 已有配置保留，新设备按名称预填
        var merged: [DeviceConfig] = found.map { d in
            store.device(named: d.name) ?? DeviceConfig.make(name: d.name, kind: Presets.guessKind(name: d.name, isComputerGroup: d.isComputerGroup))
        }
        for old in store.config.devices where !merged.contains(where: { $0.name == old.name }) { merged.append(old) }
        rows = merged
        message = found.isEmpty
            ? "没读到 UU 设备列表。请打开 UU远程 主界面并停在「全部设备」，再点「重新读取」；也可以手动添加。"
            : "从 UU 读到 \(found.count) 台设备（已排除本机），请确认类型和分辨率。"
        defaultDevice = store.config.defaultDevice ?? rows.first { $0.kind == .tablet }?.name ?? ""
    }

    func addManual() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !rows.contains(where: { $0.name == n }) else { return }
        rows.append(DeviceConfig.make(name: n, kind: Presets.guessKind(name: n, isComputerGroup: false)))
        newName = ""
    }

    func save() {
        store.config.devices = rows
        store.config.defaultDevice = defaultDevice.isEmpty ? nil : defaultDevice
    }
}

struct DeviceRow: View {
    @Binding var cfg: DeviceConfig
    var onDelete: () -> Void

    private var presetBinding: Binding<String> {
        Binding(get: { cfg.presetID ?? Presets.customID }, set: { id in
            cfg.presetID = id == Presets.customID ? nil : id
            if let p = Presets.preset(id: id) { cfg.width = p.width; cfg.height = p.height }
        })
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(cfg.name).frame(width: 150, alignment: .leading).lineLimit(1)
            Picker("", selection: Binding(get: { cfg.kind }, set: { k in
                cfg.kind = k
                if k != .computer, Presets.preset(id: cfg.presetID)?.kind != k {
                    let fresh = DeviceConfig.make(name: cfg.name, kind: k)
                    cfg.presetID = fresh.presetID; cfg.width = fresh.width; cfg.height = fresh.height
                }
            })) {
                ForEach(DeviceKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 150)

            if cfg.kind == .computer {
                Text("不切换").foregroundStyle(.secondary)
                Spacer()
            } else {
                Picker("", selection: presetBinding) {
                    ForEach(Presets.all.filter { $0.kind == cfg.kind }) { Text($0.label).tag($0.id) }
                    Text("自定义").tag(Presets.customID)
                }
                .labelsHidden().frame(width: 230)
                if cfg.presetID == nil {
                    TextField("宽", value: $cfg.width, format: .number.grouping(.never)).frame(width: 60)
                    Text("×")
                    TextField("高", value: $cfg.height, format: .number.grouping(.never)).frame(width: 60)
                }
                Toggle("HiDPI", isOn: $cfg.hiDPI)
                Spacer()
            }
            Button(role: .destructive, action: onDelete) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("移除")
        }
    }
}

struct WizardView: View {
    @ObservedObject var model: WizardModel
    var onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("UU远程分辨率伴侣 · 设备配置").font(.title2.bold())
            if let m = model.message { Text(m).foregroundStyle(.secondary) }
            if !model.trusted {
                HStack {
                    Button("打开辅助功能设置") {
                        UUReader.requestTrust()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    Text("在列表中打开「UUDisplay」的开关").foregroundStyle(.secondary)
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($model.rows) { $row in
                        DeviceRow(cfg: $row) { model.rows.removeAll { $0.name == row.name } }
                    }
                }
            }
            .frame(minHeight: 220)
            HStack {
                TextField("手动添加设备（名称需与 UU 中一致）", text: $model.newName).frame(width: 260)
                Button("添加", action: model.addManual)
                Spacer()
            }
            Divider()
            HStack {
                Picker("默认设备（读不到设备名时使用）", selection: $model.defaultDevice) {
                    Text("无").tag("")
                    ForEach(model.rows.filter { $0.kind != .computer }) { Text($0.name).tag($0.name) }
                }
                .frame(width: 380)
                Spacer()
                Button("重新读取") { model.load() }
                Button("保存") { model.save(); onSave() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 460)
    }
}

final class WizardWindowController {
    private var window: NSWindow?

    func show(onSave: @escaping () -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = WizardModel()
        let view = WizardView(model: model) { [weak self] in
            onSave()
            self?.window?.close()
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 500),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "UU远程分辨率伴侣"
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.window = nil
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
