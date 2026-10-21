// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AboutKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AboutKit", targets: ["AboutKit"])],
    targets: [.target(name: "AboutKit")]
)
