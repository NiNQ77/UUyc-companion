# UU远程分辨率伴侣 — 开发方案

来源：[交接文档](https://claude.ai/code/artifact/a4ee9729-8f10-4e86-8800-efefb42027e5)（2026-10-09）

## 目标
macOS 菜单栏工具：本机被 UU远程 控制时，按控制端设备自动创建对应分辨率的虚拟屏并设为主屏；断开后自动还原。

## 本机环境（已核实）
| 项 | 值 | 影响 |
| --- | --- | --- |
| macOS | 27.0.1 (26A434)，arm64 | 比文档参考的 Tahoe(26) 更新，CGVirtualDisplay 私有 API 需首先验证 |
| 工具链 | 仅 Command Line Tools，Swift 6.4，无 Xcode | 用 SwiftPM 构建 + 脚本打包 .app + ad-hoc 签名 |
| UU远程 | /Applications/UURemote.app，进程：UURemote / UURemoteServer / UURemoteService / UURemoteDaemon / UURemoteHelper.xpc | P0 探测对象 |
| GitHub | gh 已登录 | 可建私有仓库 |

## 技术选型
- 语言/UI：Swift + AppKit（`NSStatusItem` 菜单栏）+ SwiftUI（首次向导窗口），`LSUIElement` 隐藏 Dock 图标
- 虚拟屏：复用 FreeDisplay（MIT）的 CGVirtualDisplay ObjC 桥接头文件，放独立 ObjC target
- 主屏切换/还原：`CGBeginDisplayConfiguration` + `CGConfigureDisplayOrigin`（新屏放 (0,0) 即为主屏）
- UU 状态读取：AXUIElement（优先）→ UU 日志 → lsof/nettop → ScreenCaptureKit 截图 + Vision OCR（兜底）
- 配置存储：`~/Library/Application Support/UUDisplay/config.json`
- 自启：`SMAppService.mainApp`

## 模块划分
```
Sources/
  CGVirtualDisplayBridge/   ObjC 私有 API 头文件（来自 FreeDisplay）
  UUDisplay/
    VirtualDisplayManager   创建 / 删除虚拟屏，模式创建后不改
    DisplayArranger         设为主屏、快照与还原原布局
    UUMonitor               连入/断开事件 + 设备名（策略可插拔）
    DeviceStore             设备列表、类型、分辨率配置
    Presets                 分辨率预设表
    SetupWizard             首次启动向导
    StatusBarController     菜单：状态 / 重新配置 / 默认设备 / 暂停 / 退出 / 开机自启
    RecoveryGuard           启动时检查并修复残留状态
```

## 阶段与里程碑

### P0 探测（需用户配合，集中一次完成）
1. **虚拟屏可用性**（新增，因 macOS 27）：最小 CLI 创建 2360×1640 HiDPI 虚拟屏 → 设为主屏 → 退出后确认消失
2. **读取 UU 设备列表**：AX 树 dump UU 主窗口；失败则截图 OCR
3. **连入/断开信号 + 设备名**：依次试 AX（窗口/浮窗/菜单栏）、`~/Library` 下 UU 日志、`lsof -p` 网络连接变化、OCR
4. **UU 是否跟随主屏**：平板连入状态下切换主屏，看远程画面是否切到虚拟屏

→ 汇报 P0 结论，确认方案后进入 P1。任一项不可行时给出替代方案（如手动选择设备）。

### P1 开发
1. 虚拟屏核心 + 布局快照/还原
2. 首次启动向导（设备分类预填、分辨率选择，预设联网核实）
3. 后台监听：连入切换、断开还原、默认设备兜底、防抖
4. 菜单栏 + 开机自启 + 残留恢复
5. 打包脚本 `scripts/build-app.sh`，安装到 m4 / M1 / mini

## 预设分辨率（横屏像素，HiDPI 默认开，开发时联网核实）
平板：OPPO Pad 3 Pro 3000×2120 · iPad Air 11" 2360×1640 · iPad Air 13" 2732×2048 · iPad Pro 11" 2420×1668 · iPad Pro 13" 2752×2064 · iPad mini 2266×1488
手机：iPhone 17 2622×1206 · 通用安卓 20:9 2400×1080
自定义：宽、高、HiDPI 开关；电脑：不切换

## 关键约束
- 虚拟屏创建后不改模式（否则可能无法移除）；先建虚拟屏再枚举显示器
- 不用镜像，虚拟屏设为主屏、物理屏保持扩展
- GPL/AGPL 项目只阅读不复制
- 权限：辅助功能（AX）、屏幕录制（OCR 兜底时）

## 完成标准
- [ ] 首次启动读出 UU 设备列表并完成分类和分辨率配置
- [ ] 平板连入 5 秒内自动切换，铺满无黑边、文字清晰
- [ ] 电脑连入不做任何改动
- [ ] 断开 10 秒内恢复原状，无残留虚拟屏
- [ ] 连续连接/断开 10 次无错误
- [ ] 强退软件后无残留虚拟屏
