// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UUDisplay",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 权限引导：打开系统设置隐私页 + 拖拽授权悬浮面板（MIT，内置副本见 Vendor/PermissionFlow/VENDORED.md）
        .package(path: "Vendor/PermissionFlow"),
        // 首次启动功能导览（MIT，内置副本见 Vendor/TourKit/VENDORED.md）
        .package(path: "Vendor/TourKit"),
        // 「关于」窗口与 Debug 编号（作者自己的公用模块）
        .package(url: "https://github.com/aoyamashou/AboutKit.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "CGVirtualDisplayBridge"),
        .executableTarget(name: "vdprobe", dependencies: ["CGVirtualDisplayBridge"]),
        .executableTarget(name: "uuprobe"),
        .executableTarget(name: "uuwatch"),
        .executableTarget(name: "UUDisplay", dependencies: [
            "CGVirtualDisplayBridge",
            .product(name: "PermissionFlow", package: "PermissionFlow"),
            .product(name: "SystemSettingsKit", package: "PermissionFlow"),
            .product(name: "TourKit", package: "TourKit"),
            .product(name: "AboutKit", package: "AboutKit"),
        ]),
        .executableTarget(name: "dispoff", dependencies: ["CGVirtualDisplayBridge"]),
    ]
)
