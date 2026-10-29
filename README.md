# Chassis Plugins

Chassis 基座的插件仓库（独立于基座仓库）。

```
Chassis/                      ← 基座仓库
├── Packages/PluginAPI        ← 接口层（独立包，本仓库通过路径依赖引用）
├── Packages/PluginSupport    ← 可选共享工具（独立包）
├── Packages/PluginKit        ← 基座机制（插件不可见）
└── Chassis-Plugins/          ← 本仓库（基座仓库已忽略该目录）
    ├── docs/Plugin-Development-Guide.md
    ├── Package.swift
    └── Packages/
        ├── DockActions/      ← 点击 Dock 图标最小化 + Dock 快捷键（含黑白名单）
        ├── SlowQuit/         ← 长按 ⌘Q 才退出前台应用 + 进度环
        ├── WindowSwitcher/   ← ⌥Tab 窗口级切换器（图标 / 实时缩略图）
        ├── DockHoverPreview/ ← Dock 悬停窗口预览（图标 / 实时缩略图）
        ├── UsageStatistics/  ← 应用使用时长统计（零权限）
        └── Harness/          ← 基座探针插件（仅 Debug 注册）
```

## 构建

本仓库可独立构建（通过路径依赖读取 `../Packages/PluginAPI`、`../Packages/PluginSupport`）：

```bash
swift build
```

基座构建时会把本仓库的 target 直接编进应用二进制（见 `../Package.swift`），
因此新增插件后需要在 `Package.swift` 里声明 target，并在基座 `HostApp/PluginCatalog.swift` 注册一行。

## 约束（编译期强制）

- 插件只能依赖 `PluginAPI`（必需）与 `PluginSupport`（可选），**不得依赖 `PluginKit`**
- 插件之间互不可见（独立 module）
- target 名用 PascalCase；插件 ID 用反向域名，且发布后不可更改

## 外部插件示例

`Examples/HelloPlugin` 是一个**只依赖 C ABI**（`Packages/PluginABI`）的示例插件：
点击计数、全局快捷键、自有配置、SwiftUI 设置页。它不依赖 PluginAPI/PluginKit，
证明第三方可以用任意语言/工具链实现插件包。

```bash
./Examples/build-hello.sh     # 产出 Examples/dist/HelloPlugin.chassisplugin（ad-hoc 签名）
```

## 插件市场

`Market/` 下是发布工具：把 `Examples/dist` 里的包打 zip、算 sha256、生成索引并用 Ed25519 签名。

```bash
cd Market
swift make-index.swift --generate-key .market-key   # 一次性：生成密钥（私钥不入库）
bash build-market.sh                                # 产出 index.json + packages/*.zip
python3 -m http.server 8765                         # 本地预览
```

签名私钥只保存在本地，公钥写进基座 Info.plist 的 `ChassisMarketplacePublicKey`。

## 文档

- 插件开发规范：`docs/Plugin-Development-Guide.md`
- 基座架构（为什么这样设计）：`../docs/Host-Architecture-Design.md`
