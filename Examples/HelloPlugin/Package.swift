// swift-tools-version: 6.0
import PackageDescription

/// 外部插件示例：只依赖纯 C 的 `PluginABI`，不依赖 PluginAPI/PluginKit。
/// 这证明第三方可以用任意语言实现插件包（这里用 Swift 只是为了少写胶水代码）。
let package = Package(
    name: "HelloPlugin",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HelloPlugin", type: .dynamic, targets: ["HelloPlugin"]),
    ],
    dependencies: [
        .package(path: "../../../Packages/PluginABI"),
    ],
    targets: [
        .target(
            name: "HelloPlugin",
            dependencies: [
                .product(name: "PluginABI", package: "PluginABI"),
            ]
        ),
    ]
)
