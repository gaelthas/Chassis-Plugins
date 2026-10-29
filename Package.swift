// swift-tools-version: 6.0
import PackageDescription

/// 插件仓库。每个插件一个 target，只允许依赖 PluginAPI（必需）与 PluginSupport（可选）。
///
/// 本包可独立 `swift build`（通过路径依赖引用基座仓库里的两个接口包）；
/// 基座仓库则用路径把这里的 target 编进应用二进制（见 `../Package.swift`）。
/// 两边都不依赖对方的「包」，因此不存在循环依赖。
let package = Package(
    name: "ChassisPlugins",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Harness", targets: ["Harness"]),
        .library(name: "DockActions", targets: ["DockActions"]),
        .library(name: "SlowQuit", targets: ["SlowQuit"]),
        .library(name: "WindowSwitcher", targets: ["WindowSwitcher"]),
    ],
    dependencies: [
        .package(path: "../Packages/PluginAPI"),
        .package(path: "../Packages/PluginSupport"),
    ],
    targets: [
        .target(
            name: "Harness",
            dependencies: [
                .product(name: "PluginAPI", package: "PluginAPI"),
                .product(name: "PluginSupport", package: "PluginSupport"),
            ],
            path: "Packages/Harness",
            resources: [.process("Resources")]
        ),
        .target(
            name: "DockActions",
            dependencies: [
                .product(name: "PluginAPI", package: "PluginAPI"),
            ],
            path: "Packages/DockActions",
            resources: [.process("Resources")]
        ),
        .target(
            name: "SlowQuit",
            dependencies: [
                .product(name: "PluginAPI", package: "PluginAPI"),
            ],
            path: "Packages/SlowQuit",
            resources: [.process("Resources")]
        ),
        .target(
            name: "WindowSwitcher",
            dependencies: [
                .product(name: "PluginAPI", package: "PluginAPI"),
            ],
            path: "Packages/WindowSwitcher",
            resources: [.process("Resources")]
        ),
    ]
)
