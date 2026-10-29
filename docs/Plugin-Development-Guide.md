# 插件开发规范

> 文档版本：v1.1（对齐基座 v2.2 接口：`makeSettingsView()`、`ClickContext` 标量化、`subscribeToInterruptions`、权限按订阅类型声明）
> 配套文档：`../docs/Host-Architecture-Design.md`（基座技术方案设计，位于基座仓库）
> 所在仓库：`Chassis-Plugins`（插件源码与本文档同一个独立仓库）
> 本文档回答"怎么写"，设计文档回答"为什么这样设计"
> 适用范围：所有接入基座的内部插件

---

## 0. 三条最基本的要求

如果你的插件只违反一条规范，大概率是这三条之一：

1. **不在主线程做跨进程调用**。任何 AX / 窗口枚举 / 同步捕获都必须放进 `performBackground`，或放进 `Task`（**不得自建 `DispatchQueue`**，线程数会失控）。违反后果：整个应用的 UI（含菜单栏）冻住，用户只会认为"这个软件卡死了"。
2. **不在 `activate` 里申请权限**。只读状态，缺权限就交给基座处理。违反后果：用户第一次启用插件时被连续弹框，体验直接崩坏。
3. **不在 `deactivate` 里留下定时器、订阅、强引用**。基座会强制清理订阅和快捷键，但**清理不了你自己的 `Timer`、`Task`、`NotificationCenter` 观察者**。违反后果：插件关闭后仍在后台跑，CPU 占用异常，且极难定位。

---

## 1. 五分钟上手

### 1.1 最小可运行插件

```swift
import PluginAPI
import SwiftUI

@MainActor
final class MyPlugin: FeaturePlugin {
    static let manifest = PluginManifest(
        id: "com.example.plugin.my-plugin",     // 反向域名，全局唯一，不可更改
        version: "1.0.0",                       // 语义化版本
        minHostVersion: "1.0.0",                // 依赖的基座最低版本
        title: "我的插件",
        summary: "一句话说明这个插件做什么",
        iconSystemName: "sparkles",             // SF Symbol
        requiredCapabilities: [],               // 没有就留空，见 §3
        optionalCapabilities: [],
        resourceBundle: .module                 // 插件自己的本地化资源
    )

    private var context: PluginContext?         // 可强持有，见 §2.1
    private var subscription: Subscription?
    private let model = MySettingsModel()       // 设置页状态放在实例上

    func activate(context: PluginContext) throws {
        self.context = context
        // 在这里注册订阅 / 快捷键 / 恢复状态
    }

    func deactivate() {
        // 在这里释放自己的资源（订阅可省略，基座会清理）
        subscription?.cancel()
        subscription = nil
        context = nil
    }

    // 设置页是实例方法：能读到 self 上的 model，切换页面不会丢状态
    func makeSettingsView() -> AnyView {
        AnyView(MySettingsView(model: model))
    }
}
```

### 1.2 注册到基座

只改一处，加一行：

```swift
// HostApp/PluginCatalog.swift
@MainActor
enum PluginCatalog {
    static let all: [any FeaturePlugin.Type] = [
        MyPlugin.self,
    ]
}
```

`@MainActor` 不能省：`FeaturePlugin` 是主 actor 隔离的协议，`manifest` 只能在主 actor 读。

### 1.3 新增插件的固定步骤

| 步骤 | 操作 |
|---|---|
| 1 | 在本仓库 `Packages/` 下新建 target，命名 `MyPlugin` |
| 2 | 本仓库 `Package.swift` 中声明 target 与依赖：`PluginAPI`（必需）、`PluginSupport`（可选），**不得依赖 `PluginKit`** |
| 3 | 实现 `FeaturePlugin`，`id` 使用反向域名且此后不再修改 |
| 4 | 实现 `makeSettingsView()`（即使是空页也要返回一个有意义的 View） |
| 5 | 在基座仓库 `HostApp/PluginCatalog.swift` 的 `PluginCatalog.all` 加一行 |
| 6 | 跑通 §8 自检清单 |

`id` 一旦发布**永不可改**——它是配置存储的键，改了等于用户配置全部丢失。

---

## 2. 生命周期契约

```
用户开启开关
    ↓
基座检查 requiredCapabilities
    ├─ 缺失 → 不实例化，状态 missingCapabilities（你的代码不会被调用）
    └─ 齐备 → 实例化 → activate(context)
                ├─ 抛错 → 状态 failed（你的 deactivate 不会被调用）
                └─ 成功 → active
                            ↓
                       用户关闭开关
                            ↓
                       deactivate() → 基座强制清理订阅与快捷键
```

### 必须遵守

| 规则 | 说明 |
|---|---|
| `activate` 幂等 | 基座会做状态检查，但你也不要有"只会调用一次"的假设 |
| `deactivate` 幂等 | 可能被调用多次，且**不得抛错**（签名本身也不允许） |
| `deactivate` 必须同步完成清理 | 不要在 `deactivate` 里 `Task { ... }` 做异步清理——那时插件已不被基座引用，行为不可预测 |
| `activate` 抛错后 `deactivate` 不会被调用 | 若 `activate` 中途失败，**必须自己回滚**已创建的资源 |
| 不假设执行顺序 | 不要依赖其他插件是否先启动、是否启用 |

### 2.1 `context` 的生命周期

这是最常被问到的细节，答案很短：

| 问题 | 答案 |
|---|---|
| 每次 `activate` 都是新的 context 吗？ | 不是。同一插件实例在 enabled 期间拿到的是**同一个** context |
| 可以强持有吗？ | 可以。它由基座持有，生命周期覆盖整个 enabled 期，不会先于插件失效 |
| 需要 `[weak context]` 吗？ | 不需要。`PluginContext` 是 `AnyObject`，但你没有循环引用风险 |
| `deactivate` 之后还能调用吗？ | 能调，但不生效——订阅、快捷键、通知点击回调都已摘除 |
| `deactivate` 里要置 nil 吗？ | 可选。置 nil 只是让"关闭后误用"在编译期更难发生，推荐这么做 |

所以正确的写法是 `self.context = context`，然后在闭包里用 `guard let context = self.context`，不要在每次订阅时都去弱引用它。

### 禁止

```swift
// ❌ 单例：基座已经持有你的实例，再搞一个 shared 会出现两份状态
static let shared = MyPlugin()

// ❌ 在 activate 里申请权限
try context.permissions.request(.accessibility)   // 必须由用户点击触发

// ❌ 在 deactivate 里异步清理
func deactivate() {
    Task { await cleanup() }   // 不可靠，插件已被基座放弃
}

// ❌ 插件之间直接通信
SomeOtherPlugin.shared.doThing()   // 插件之间必须完全隔离
```

---

## 3. 能力声明：`required` 与 `optional`

**能少填就少填。** 每多一个 `required`，用户就多一次被要求授权的机会，而每一次授权请求都在消耗信任。

| 字段 | 语义 | 缺失时 |
|---|---|---|
| `requiredCapabilities` | 缺一不可 | 插件**不会启动**，状态 `missingCapabilities` |
| `optionalCapabilities` | 有则更好 | 插件正常启动，`context.permissions.status(of:)` 返回 `false`，自行降级 |

### 常见错误

| 场景 | 错误做法 | 正确做法 |
|---|---|---|
| 只想注册全局快捷键 | 声明 `.inputMonitoring` | **不声明任何能力**。`RegisterEventHotKey` 不需要任何授权（§4.3） |
| 想读前台应用名 | 声明 `.accessibility` | `NSWorkspace.frontmostApplication` 是纯 AppKit，不需要授权；点击场景下 `ClickContext.frontmostPID` 已给出 |
| 想监听鼠标点击 / 指针移动 | 声明 `.inputMonitoring` | 声明 **`.accessibility`**。鼠标 tap 与 `NSEvent` 全局监听都由辅助功能门控（§3.1） |
| 想监听键盘原始事件 | 声明 `.accessibility` | 声明 **`.inputMonitoring`**。键盘 tap 由输入监控门控（§3.1） |
| 想捕获窗口缩略图 | 声明 `.accessibility` + `.screenCapture` 都为 required | `.screenCapture` 放 `optional`，缺失时降级为纯文本列表 |
| 想枚举窗口列表 | 声明 `.inputMonitoring` | 只需要 `.accessibility`（`CGWindowListCopyWindowInfo` 的基础信息不需要，但读窗口标题需要 AX） |

### 3.1 按订阅类型选能力

**不要凭"我要监听输入"这句话去选能力，要按具体订阅选**：

| 你要用的 API | 该声明 |
|---|---|
| `context.hotKeys.register(...)` | 无（不需要任何能力） |
| `context.inputBus.subscribeToKey(...)` | `.inputMonitoring` |
| `context.inputBus.subscribeToClick(...)` | `.accessibility` |
| `context.inputBus.subscribeToPointerMove(...)` | `.accessibility` |
| `context.inputBus.subscribeToInterruptions(...)` | 无（基座内部事件，不涉及新授权） |
| 任何 `AXUIElement*` 调用 | `.accessibility` |
| `CGWindowListCopyWindowInfo` | `.accessibility`（读标题需要；仅几何信息不需要） |
| ScreenCaptureKit / `CGWindowListCreateImage` | `.screenCapture` |

声明错误的后果不是"权限没弹出来"，而是**用户在错误的系统设置页里授权，功能依然不工作**，然后认为插件坏了。

### 降级必须真的可用

```swift
// ✅ 正确：能力缺失时功能降级但插件仍工作
if context.permissions.status(of: .screenCapture) {
    let image = await captureThumbnail(window)
    render(image)
} else {
    renderPlaceholder()   // 不是空白，要给出可用替代
}
```

---

## 4. 五项基座能力

> 完整接口定义见设计文档 §5.5。此处只讲用法与陷阱。
> `context.store` 与 `context.logger` 不在这五项里——它们是基础设施而非能力，分别见 §7 与 §10。

### 4.1 `context.inputBus` — 输入事件

**唯一可用于感知鼠标/键盘的入口。不得自建 `CGEvent.tapCreate`。**

```swift
// 鼠标点击：能区分左右键与连击（单击 / 双击）
subscription = context.inputBus.subscribeToClick { click in
    let app = click.frontmostPID.flatMap { NSRunningApplication(processIdentifier: $0) }
    context.logger.info("\(click.button) x\(click.clickCount) @ \(click.location)，点击前前台: \(app?.localizedName ?? "-")")
}

// 指针移动（已由基座节流 ≤60Hz，不要指望精确到每个像素）
moveSub = context.inputBus.subscribeToPointerMove { point in
    updateHoverState(at: point)
}

// tap 失效（系统超时禁用 / 权限被收回）：有进行中会话就必须处理
interruptSub = context.inputBus.subscribeToInterruptions { interruption in
    // 例如"按住 ⌘ 等待点击"的会话要在这里作废，否则下一次点击会被误判
    cancelPendingHold()
}

// 键盘：声明式预筛 + 可选同步拦截 + 主线程业务
//
// 需要跨线程共享的"当前是否按住"状态，一律用基座提供的 AtomicFlag。
// 不能用 var / NSLock / 引用类型属性的普通读写。
private let holdFlag = AtomicFlag()

keySub = context.inputBus.subscribeToKey(
    KeyFilter(keyCodes: [12], requiredFlags: .maskCommand),   // ⌘Q（包含语义：⌘⇧Q 也会命中）
    syncIntercept: { [holdFlag] event in
        // ⚠️ 这段跑在 tap 线程：只能读标量、做位运算、读 AtomicFlag
        // 禁止：分配内存、加锁、Dispatch、访问 AppKit / NSObject
        // 必须显式 [holdFlag] 捕获：直接写 holdFlag 会隐式捕获 self，
        // 而 self 是 @MainActor 类，@Sendable 闭包捕获它会直接编译失败。
        return holdFlag.value ? .consume : .passthrough
    },
    handler: { event in
        // 这里才是主线程，可以随便写业务
        startHoldCountdown()
        holdFlag.value = true
    }
)
```

**陷阱清单**：

| 陷阱 | 说明 |
|---|---|
| 在 `syncIntercept` 里访问插件状态 | 编译期会被 `@Sendable` 拦住大部分情况，但用 `class` + 引用捕获仍可能绕过。任何需要"当前是否按住"这类状态，必须用基座提供的 `AtomicFlag` |
| 在 `syncIntercept` 里调 `DispatchQueue.main.sync` | **会死锁**。tap 线程等主线程，主线程可能在等 tap 完成 |
| 认为 `handler` 能阻止事件 | 不能。`handler` 在事件已分发之后才执行，只有 `syncIntercept` 能吞 |
| 用 `pointerMove` 做重活 | 主线程回调，重活会拖慢整个 UI。只做轻量状态更新 |
| 忘记订阅 `subscribeToInterruptions` | 系统超时会禁用 tap，基座会重新 enable 并广播 `InputInterruption`。若你有"按住未完成"的会话状态，必须在这里清理，否则会在失效窗口内静默丢事件 |
| 在 `syncIntercept` 里直接写实例属性 | `holdFlag.value` 这种写法会隐式捕获 `self`（`@MainActor` 类），`@Sendable` 闭包捕获它编译不过。必须 `[holdFlag]` 显式捕获 |
| 以为 `requiredFlags` 是精确匹配 | 它是**包含语义**：`.maskCommand` 同时命中 `⌘Q` 与 `⌘⇧Q`。要精确匹配就在 `handler` 里自行比对 `event.flags` |

**"点击前状态"的正确做法**：

先分清两类信息，它们的获取方式完全不同：

| 信息 | 怎么拿 |
|---|---|
| 点击前的**前台应用** | 不用预取。`click.frontmostPID` 已经是点击瞬间的值（基座在 tap 线程读的原子快照） |
| 点击前的**窗口状态**（是否可见、是否全屏…） | 基座无法提供，必须自己预取：指针移动时缓存，点击时读缓存 |

```swift
// 需要"点击时窗口是否可见"这类依赖 AX 的信息？不要期望基座提供，它无法提供。
// 自己预取：指针移动时缓存，点击时读缓存
moveSub = context.inputBus.subscribeToPointerMove { point in
    hoverCache[point] = queryVisibleWindowAsync(point)   // 经 performBackground 查询，异步回填
}

clickSub = context.inputBus.subscribeToClick { click in
    let cached = hoverCache[click.location]     // 读缓存，可能略旧，这是可接受的
}
```

### 4.2 `context.permissions` — 权限

```swift
// 随时可查
if context.permissions.status(of: .accessibility) { ... }

// 申请：只能挂在按钮点击上
Button("授权") {
    context.permissions.request(.accessibility)
}
```

| 规则 | 说明 |
|---|---|
| 不在 `activate` 里 `request` | 唯一允许的位置是用户点击的事件处理器内 |
| 不在定时器/延迟里 `request` | 用户无法把弹框归因到自己的操作 |
| 重复 `request` 无效 | 基座对每种权限每启动只弹一次；之后请引导用户去系统设置 |
| 受限 ≠ 未授权 | `context.permissions.isRestricted(.accessibility)` 为 true 表示被 MDM 或系统策略禁用，此时 `request` 必然无效，UI 应直接说明原因 |
| 自己探测也合法 | `AXIsProcessTrusted()` 可以直接调，与 `context.permissions.status` 等价 |

### 4.3 `context.hotKeys` — 全局快捷键

```swift
// activate 时注册（从自己的存储恢复用户上次设定）
let spec = context.store.value(HotKeySpec.self, forKey: "hotkey") ?? .defaultToggle
try context.hotKeys.register(spec) { [weak self] in
    self?.toggle()
}

// 设置页改键。spec 必须是 model 上的可写属性——
// @State 会在切换页面时重置，计算属性则取不到 $ 绑定。
@Observable
final class MySettingsModel {
    var spec: HotKeySpec
    init(store: PluginStore) {
        spec = store.value(HotKeySpec.self, forKey: "hotkey") ?? .defaultToggle
    }
}

HotKeyRecorder(
    spec: $model.spec,
    availability: { context.hotKeys.availability(of: $0) },   // 调用者身份由 context 决定，不传 pluginID
    onCommit: { newSpec in
        try context.hotKeys.update(newSpec)     // 抛错时控件自动回滚，旧键继续生效
        context.store.set(newSpec, forKey: "hotkey")
    }
)
```

`.defaultToggle` 是**插件自己**为 `HotKeySpec` 定义的静态常量（基座不提供任何默认快捷键），例如：

```swift
extension HotKeySpec {
    static let defaultToggle = HotKeySpec(keyCode: 0x23, modifiers: [.option, .command])  // ⌥⌘P
}
```

| 规则 | 说明 |
|---|---|
| 冲突必须告知用户 | `register` / `update` 抛错时必须显示"已被 XX 占用"，不能只记日志 |
| 快捷键存自己的 `store` | 基座不持久化你的快捷键 |
| 不要自己调 `RegisterEventHotKey` | 会与基座及其他插件静默冲突 |
| 不需要任何权限 | 不为快捷键声明 `inputMonitoring` |

### 4.4 `context.notifier` — 通知

```swift
context.notifier.post(.init(
    id: "state-changed",                    // 同 id 会替换旧通知
    title: "已完成",
    body: "共处理 3 个窗口",
    priority: .low,
    coalescingKey: "state",                 // 60s 内相同 key 只保留最新一条
    onClick: { [weak self] in self?.openSettings() }
))
```

| 规则 | 说明 |
|---|---|
| 不要用它做反馈的主要形式 | 通知是"应用不在前台时的告知"，用设置页内状态展示更好 |
| 高频状态用 `coalescingKey` | 否则会被基座节流丢弃（同插件 5 秒一条） |
| `onClick` 只在插件 active 时有效 | 插件被关闭后点击被忽略并记日志 |
| 通知授权被拒不影响插件运行 | 静默降级，不要因此抛错或禁用功能 |

### 4.5 `context.performBackground` — 后台执行

```swift
// ✅ 正确
let windows = try await context.performBackground {
    MyAXHelper.enumerateWindows(pid: targetPid)   // 闭包里是你的系统调用
}

// ❌ 错误一：主线程直接调
let windows = MyAXHelper.enumerateWindows(pid: targetPid)   // UI 可能冻住数秒

// ❌ 错误二：自己建队列绕过
DispatchQueue.global().async { ... }   // 线程数不可控，且失去了 @Sendable 的保护
```

| 规则 | 说明 |
|---|---|
| 所有可能变慢的跨进程调用都进 `performBackground` | AX、`CGWindowListCopyWindowInfo`、以及任何同步封装的捕获 API。ScreenCaptureKit 原生的 `async` API 本身就不阻塞，直接在 `Task` 里 `await` 即可，不必再包一层 |
| 闭包必须 `@Sendable` | 编译期会阻止你捕获 Main Actor 状态。需要传参就在调用前拷贝成值 |
| 结果是 `Sendable` 值类型 | 不要返回 `AXUIElement`（非 Sendable），应转换后再返回 |
| 串行执行 | 基座用单一串行队列，两个 `performBackground` 不会并发。目标应用卡死时，你的第二个调用会排在后面 |

**不要把它当成"后台任务容器"**：它只保证"不在主线程、且全局串行"，没有取消、没有优先级、没有进度汇报——这些由你自己的 `Task` 组织。它适合"单次调用可能卡几秒"的场景，不适合"跑一个 30 秒的批处理循环"（那种情况应拆成多次调用，中间让出）。

---

## 5. 直接调用系统 API 的正确姿势

基座**不提供**系统 API 封装（设计文档 §4.4）。你需要什么就自己调，但有三条纪律：

### 5.1 调用前自查权限

```swift
guard context.permissions.status(of: .screenCapture) else {
    showNeedsPermission()
    return
}
let image = await SCKCapture.capture(window: windowID)
```

基座**不会**拦截你的调用。没有权限时系统会静默失败或反复弹系统的拒绝提示，你只会看到"功能不工作"。

### 5.2 慢调用不上主线程

见 §4.5。判断标准很简单：**这个调用会不会因为目标应用卡住而变慢？** 会 → `performBackground`。

典型需要包裹的：

- `AXUIElementCopyAttributeValue` 及其所有变体
- `AXUIElementPerformAction`
- `CGWindowListCopyWindowInfo`
- 任何遍历多窗口、多应用的循环

不需要包裹的：

- `NSWorkspace.shared.frontmostApplication`（属性读取，读的是内存中的状态）
- 纯 `NSRunningApplication` 属性访问（`localizedName` / `bundleIdentifier` / `isTerminated` 等）

**容易误判的一个：`NSRunningApplication.activate()`。** 它看起来是"发个请求就返回"，实际会同步等待 LaunchServices 与目标应用响应；目标应用卡住时，它和 AX 调用一样会拖住调用线程。

- 不要在 Main Actor 上直接调用它；
- 需要激活应用时，包进 `performBackground`，或改用 `NSWorkspace.shared.openApplication(at:configuration:)` 的异步形式。

### 5.3 不做需要全局唯一的事

**不得**实现这些：

| 禁止 | 因为 |
|---|---|
| `CGEvent.tapCreate` | 全局事件源必须唯一，用 `inputBus` |
| `RegisterEventHotKey` | 全局快捷键必须仲裁，用 `hotKeys` |
| `UNUserNotificationCenter.add` 直接调用 | 会让你的通知绕过节流，淹没用户，用 `notifier` |
| `AXIsProcessTrustedWithOptions(prompt: true)` | 会让权限弹框绕过收敛，用 `permissions.request` |
| 修改其他插件的 `UserDefaults` suite | 配置隔离 |

---

## 6. 设置页规范

### 6.1 结构与绑定

设置页的**视图**会被反复重建（基座每次切回该插件都会重新调用 `makeSettingsView()`），但调用的是**同一个插件实例**。因此模型可以（也应该）挂在插件对象上。

```swift
// ✅ 推荐：插件对象持有模型，View 只读
@MainActor
@Observable
final class MySettingsModel {
    var threshold: Double
    private let store: PluginStore
    init(store: PluginStore) {
        self.store = store
        self.threshold = store.value(Double.self, forKey: "window.threshold") ?? 0.5
    }
    func save() { store.set(threshold, forKey: "window.threshold") }
}

@MainActor
final class MyPlugin: FeaturePlugin {
    private var model: MySettingsModel?      // activate 时创建一次，之后一直复用

    func activate(context: PluginContext) throws {
        if model == nil { model = MySettingsModel(store: context.store) }
    }

    // 每次切回本插件都会调用，但返回的是同一个 model →
    // 改到一半的参数、正在录制的快捷键都不会丢。
    // 基座只在 active 时调用它，model 必然已创建。
    func makeSettingsView() -> AnyView {
        guard let model else { return AnyView(Text("插件未激活")) }
        return AnyView(MySettingsView(model: model))
    }
}

// ❌ 错误：状态在 View 里，切走再切回就丢了
struct BadView: View {
    @State private var threshold = 0.5   // 会被重置
}
```

### 6.2 必须遵守的 UI 约定

| 约定 | 原因 |
|---|---|
| 不实现自己的"启用/禁用"开关 | 开关由基座在列表里统一渲染，插件无权隐藏 |
| 不实现"关于/版本"区块 | 基座关于页统一展示 |
| 不实现「卸载」按钮 | 静态链接的代码无法移除，只能「重置配置」。基座不提供假的卸载按钮，插件也不要自己造 |
| 不实现权限状态页 | 基座权限页统一展示；你只需在功能不可用处给一行文案 + 跳转按钮（URL 见附录 A） |
| 使用 `Form` + `.formStyle(.grouped)` | 与其他页面视觉一致 |
| 子开关用 `Toggle`，参数用 `Picker`/`Slider` | 遵循 macOS HIG |
| 文案走 `LocalizedStringKey`，并带 `bundle: manifest.resourceBundle` | 插件的 `.strings` 在自己的 target 里，`Text(_:)` 默认查 main bundle，不显式传 bundle 会全部退化成 key |
| 改设置后立即生效 | 不要让用户"重启应用"才生效。需要重启说明配置没走"写 store → 立刻更新运行时状态"这条单向流 |
| 提供「重置此插件配置」入口 | 基座提供 `store.removeAll()`，建议在设置页底部放置 |

### 6.3 空状态必须有内容

即使插件暂时没有可配置项，也要给出说明：

```swift
Text("此插件无需配置，启用后即生效。")
    .foregroundStyle(.secondary)
```

不要返回 `EmptyView()` —— 用户看到一片空白会以为界面坏了。

---

## 7. 配置存储规范

```swift
// 读（带默认值）
let threshold = context.store.value(Double.self, forKey: "threshold") ?? 0.5

// 写
context.store.set(threshold, forKey: "threshold")
```

| 规则 | 说明 |
|---|---|
| 键名用点分层 | 如 `"window.minSize"`。每个插件有独立 suite，**跨插件不会撞名**；分层的意义是同插件内可读、可分组、可批量清理（如全部 `window.*`） |
| **必须存 schema 版本** | 见下 |
| 不要存派生数据 | 能算出来的不存，避免不一致 |
| 不要存敏感信息 | `UserDefaults` 是明文 plist |
| 直接存 `Codable` 类型 | `HotKeySpec` 等类型本身已 `Codable`，不必拆成多个键；自定义结构记得一并声明 |

### 配置版本迁移模板

下面模板里 v0 的 `"threshold"` 就是早期未分层的键名，迁移把它改成分层键——这是迁移最常见的用途之一，不代表新代码可以继续用泛名。

```swift
private func migrateIfNeeded() {
    let current = context.store.value(Int.self, forKey: "_schemaVersion") ?? 0
    guard current < 2 else { return }

    if current < 1 {
        // v0 → v1：旧键改名
        if let old = context.store.value(Double.self, forKey: "threshold") {
            context.store.set(old, forKey: "window.threshold")
        }
    }
    context.store.set(2, forKey: "_schemaVersion")
}
```

**第一个版本就要写这段。** 上线后再补迁移逻辑，只能在"用户配置已丢失"和"写一堆兼容代码"之间选。

---

## 8. 提交前自检清单

### 编译不过（不用等审查，构建就会失败）

- [ ] 未依赖 `PluginKit`
- [ ] 未 `import` 其他插件的 module
- [ ] `manifest` 全部必填字段已填（`id` / `version` / `minHostVersion` / `title` / `summary` / `iconSystemName` / `resourceBundle`）
- [ ] `deactivate()` 无返回值、无 `throws`
- [ ] `syncIntercept` 内没有隐式捕获 `self`（写成 `[flag]` 显式捕获）
- [ ] 实现了 `makeSettingsView()`（协议要求，漏了直接编译不过）

### 会被审查打回

- [ ] 未自建 `CGEvent.tapCreate` / `RegisterEventHotKey` / `UNUserNotificationCenter.add`
- [ ] 未在 `activate` 中调用 `request`
- [ ] 所有 AX / 窗口枚举调用都在 `performBackground` 或 `async` 上
- [ ] `syncIntercept` 内无内存分配、无锁、无 `Dispatch`、无 AppKit
- [ ] `deactivate` 清理了全部自建资源（`Timer` / `Task` / `NotificationCenter` / 观察者）
- [ ] 无 `static let shared`
- [ ] 调用系统 API 前自查了对应 Capability
- [ ] 能力声明与订阅类型匹配（键盘 → `.inputMonitoring`；点击 / 指针 → `.accessibility`）
- [ ] 有进行中会话的插件订阅了 `subscribeToInterruptions` 并在其中清理
- [ ] 日志中无窗口标题、文件路径、剪贴板、用户输入

### 会导致线上问题（最容易漏）

- [ ] 权限被收回时能正确降级（拔掉权限手动测一次）
- [ ] 插件关闭后无残留行为（关闭后观察 30 秒 CPU）
- [ ] 快捷键冲突时有明确提示，且改键失败后功能仍正常
- [ ] 设置页在反复切换插件后状态不丢失（model 在插件实例上，不在 View 的 `@State` 里）
- [ ] 配置有 `_schemaVersion`
- [ ] 通知用了 `coalescingKey`，不会连发
- [ ] 空数据、零窗口、无前台应用等边界不崩溃

---

## 9. 症状 → 原因对照

排障时先查这张表：

| 症状 | 最可能的原因 |
|---|---|
| 应用整体卡顿、菜单栏无响应 | 在主线程做了 AX / 窗口枚举 / 屏幕捕获。查所有没包 `performBackground` 的调用 |
| 第一次按键有延迟，之后正常 | `syncIntercept` 里做了重活，或首次调用触发了类加载 / 内存分配 |
| 系统键盘整个卡住 | `syncIntercept` 里 `DispatchQueue.main.sync` 造成死锁 |
| 插件开关打开但什么都不发生 | `requiredCapabilities` 未满足，插件根本没 `activate`。查插件列表的状态徽章 |
| 用户被连续弹权限框 | `activate` 里调了 `request`，或多个插件同时申请 |
| 关闭插件后 CPU 仍占用 | 残留 `Timer` / `Task` / 观察者未在 `deactivate` 清理 |
| 功能突然全部失效、无任何报错 | Event Tap 被系统超时禁用。检查是否订阅了 `subscribeToInterruptions`，只在失效窗口内丢事件属于预期 |
| 右键或双击被当成普通单击 | 没读 `click.button` / `click.clickCount`，或自己重写了点击判定。判定由基座完成，插件只消费结果 |
| 点击时拿到的"前台应用"总是错的 | 用了 `NSWorkspace.frontmostApplication`（点击后才查，已是新世界）。应读 `click.frontmostPID` |
| 声明了权限、系统设置里也授权了，功能还是不工作 | 能力声明错了：`subscribeToClick` / `subscribeToPointerMove` 要 `.accessibility`，不是 `.inputMonitoring`（§3.1） |
| 快捷键被别的功能抢走 | 未走 `hotKeys` 仲裁，或未处理 `HotKeyError.conflict` |
| 切换设置页后配置回退 | 状态放在了 View 的 `@State` 里，应移到插件持有的模型 |
| 老用户升级后配置丢失 | 没有 `_schemaVersion` 或无迁移逻辑 |
| 通知完全不出现 | 用户拒绝了通知授权，或触发了节流被丢弃（查日志） |

---

## 10. 命名与代码风格

| 项 | 约定 | 示例 |
|---|---|---|
| 插件 ID | `<bundle-id 前缀>.plugin.<短横线名>` | `com.example.plugin.window-snap` |
| target 名 | PascalCase，与插件主题一致 | `WindowSnap` |
| 插件类名 | `<主题>Plugin` | `WindowSnapPlugin` |
| 存储键 | 小写点分层 | `"window.minSize"`、`"hotkey.toggle"` |
| 日志 | 用 `context.logger`，带上下文 | `logger.info("snapped \(count) windows")` |
| 注释 | 只解释"为什么"，不解释"是什么" | — |

**代码注释的一个具体要求**：凡是"看起来可以更简单但没那么做"的地方，必须写清原因。例如：

```swift
// 不用 context.permissions.request：activate 阶段申请会让用户
// 在插件刚打开时被弹框，无法归因到自己的操作。这里只标状态，由权限页引导。
```

否则下一个人（可能是三个月后的你）一定会把它"优化"掉。

### 10.1 跳转系统设置的标准写法

基座**不封装**这个动作（设计文档 §4.4.1），但每个插件都会用到它，所以标准 URL 统一放这里，不要自己拼：

```swift
enum SystemSettingsPane {
    static func open(_ pane: Pane) {
        let anchor: String
        switch pane {
        case .accessibility:  anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .screenCapture:  anchor = "Privacy_ScreenCapture"
        }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }

    enum Pane { case accessibility, inputMonitoring, screenCapture }
}
```

注意事项：

- 通知不在这套 URL 里，它的面板是独立的（`x-apple.systempreferences:com.apple.preference.notifications`）。
- 这些 URL 由系统决定，跨大版本可能变化。**拿不到时不要死循环重试**——`NSWorkspace.open` 返回 `false` 就退回到"请手动打开 系统设置 → 隐私与安全性"的文案。
- 只引导，不诱导：按钮文案写「打开系统设置」，不要写「立即授权」——后者会让用户以为应用能自己完成授权。

---

## 11. 参考

| 想了解 | 去看 |
|---|---|
| 为什么基座不封装系统 API | 设计文档 §4.4 |
| 输入总线为什么是三段式 | 设计文档 §6.3 |
| 权限申请为什么必须收敛 | 设计文档 §4.4.6 |
| 权限为什么按订阅类型映射 | 设计文档 §5.4、本文 §3.1 |
| 点击快照为什么只给 pid、不给 `NSRunningApplication` | 设计文档 §4.4.3、§7 |
| 设置页为什么是实例方法而不是 manifest 里的闭包 | 设计文档 §5.1 |
| 为什么插件不能动态加载 | 设计文档 §3.4、§13 |
| 安全防护的真实强度 | 设计文档 §9.2 |
| 插件状态机全貌 | 设计文档 §6.1 |
| 全部接口的权威签名 | 设计文档 附录 A |
