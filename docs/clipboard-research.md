# 自动粘贴实现与验证

核对日期：2026-10-27。以下是源码和社区证据；它们不能替代本应用在 Edge、QQ 等实际输入框中的验收。

## 参考实现

- [Maccy 2.8.0 Clipboard.swift](https://github.com/p0deje/Maccy/blob/2.8.0/Maccy/Clipboard.swift#L113-L135)：在 GUI 进程中构造 `combinedSessionState` 事件源，设置本地事件抑制过滤，发送单对 ⌘V 到 `cgSessionEventTap`。[History.select](https://github.com/p0deje/Maccy/blob/2.8.0/Maccy/Observables/History.swift#L324-L354)先关闭面板，再复制、粘贴；[FloatingPanel](https://github.com/p0deje/Maccy/blob/2.8.0/Maccy/FloatingPanel.swift#L20-L35)使用非激活面板和 `animationBehavior = .none`。本项目保留 XPC 辅助进程，但必须让它加入同一个 GUI 登录会话。
- [Clipy PasteService（e68ccf4）](https://github.com/Clipy/Clipy/blob/e68ccf48cefec2fd77d1cec48c5ea079fbf60858/Clipy/Sources/Services/PasteService.swift#L128-L154)：先检查辅助功能权限，再异步发送一对快捷键到 annotated session tap。
- [CopyQ macplatformwindow（d39e44c）](https://github.com/hluk/CopyQ/blob/d39e44c3853a8aa05a77073e3d8e48d29cddb043/src/platform/mac/macplatformwindow.mm#L120-L143)：让出运行循环，等待目标窗口恢复焦点，再发送快捷键。
- [Copyosity paste.rs（aad3c2b）](https://github.com/vakovalskii/copyosity/blob/aad3c2bd6c6a4fd9fdedc935ab019f8a4bb1fdcc/src-tauri/src/clipboard_macos/paste.rs#L147-L158)：目标位于前台时使用 session tap；源码记录部分原生应用忽略 `postToPid`，同时发送多个 tap 会造成重复粘贴。其[目标记忆](https://github.com/vakovalskii/copyosity/blob/aad3c2bd6c6a4fd9fdedc935ab019f8a4bb1fdcc/src-tauri/src/clipboard_macos/mod.rs#L273-L340)在自身面板获取焦点前保存外部应用，并记录最近的外部激活应用。

## 本次选择

选择记录后，主进程先完整读取并校验载荷，再写入剪贴板；目标应用、辅助功能权限或 AX 快照不可用都不再阻止基本复制。写入成功后立即结束面板会话、释放键盘并把焦点交回打开前保存的应用，然后检查已有权限、尝试自动粘贴。失败使用非激活提示，内容保留供手动 ⌘V；权限请求仍由首次启用、“允许自动粘贴”和设置里的明确操作触发，授权后不会重放旧选择。

AX 快照是可选增强：有快照时核对并恢复原窗口/控件，缺失、过期或 helper 重启丢失 token 时允许应用级交接。浏览器 AX 子元素可属于 renderer PID，不要求与主应用 PID 相等。AX 证据分为 matched / unknown / conflict：引用失效、窗口/角色不可读或恢复无效归 unknown，停止强制 AX 恢复，采用至少 0.18 秒的原应用稳定交接；只有可靠证据明确指向另一窗口/输入控件才 conflict，且本次请求内保持取消。最终投递前首次失去 AX 增强也先继续本次请求的稳定等待，尚未发送任何事件。已观察到用户点击别处、切应用/窗口/控件则取消，不能用缺失快照绕过已知变化。

这一 PID 边界有 [WebKit 远端 AX 源码](https://github.com/WebKit/WebKit/blob/9296bd1b87efef73a9dd2883a91e594d11379cca/Source/WebKit/UIProcess/mac/WebViewImpl.mm#L4201-L4275)支持，但不能据此断言本次 Edge/QQ 就是跨进程元素造成的失败：[Chromium 架构说明](https://chromium.googlesource.com/chromium/src/+/master/docs/accessibility/overview.md)把原生 AX 树放在 browser 进程。本项目原有捕获逻辑允许缺失焦点元素；实际 nil 快照还可能来自授权、超时或 XPC 生命周期，需要分别诊断。

自动粘贴采用 `combinedSessionState` 与单次 `cgSessionEventTap`。辅助进程先检查权限、目标输入位置、锁屏、按键释放及剪贴板版本；事件发送器在构造事件前后确认目标 PID 仍在前台。按下和抬起在同一次同步调用里发送，不并行投递多个路径，也不在发送后自动重试。快捷键面板初始保留，指针进入后离开使用正常关闭延时；Escape、外部点击和失活也结束会话。

不使用鼠标点击猜测输入框，不使用 AppleScript 兜底。`CGEvent` 投递没有编辑器消费确认：函数成功仅表示已提交事件，不能显示成“已确认插入”。

## 权限与提示框

- [Maccy #1381](https://github.com/p0deje/Maccy/issues/1381)报告自编译版本只复制不粘贴，社区通过重新加入辅助功能列表恢复；[CopyQ #1030](https://github.com/hluk/CopyQ/issues/1030)记录开关仍存在但授权失效的相似情况。这些属于社区个案，不证明所有粘贴失败都由授权导致。
- [Apple AXIsProcessTrusted](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted)检查当前执行进程。主程序或命令行测试的授权结果不能代替实际发事件的 helper 状态。Ad-hoc 构建的签名身份依赖代码哈希，更新后可能需要使用者重新授权；应用不自动授予或重置权限。
- [Apple NSAlert.layout](https://developer.apple.com/documentation/appkit/nsalert/layout())提供立即排版。独立展示 `NSAlert.window` 前完成排版，避免模板抑制框、空按钮和截断文字。
- [Apple XPC 服务指南](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)说明服务可能被终止和重启；辅助进程中的临时焦点引用必须按会话有效性处理，不能将内存 token 当成持久状态。

## 会话边界根因与修复（2026-10-27）

本轮运行真实 `ClipboardStore` 与 `ClipboardPresentation` 后发现两处状态管理缺陷：

1. `NSWindow.didBecomeKey` 监听在没有任何输入目标会话时，也会把“本应用编辑器打断目标”的标志置为真。设置窗口关闭后，下一次鼠标进入会捕获新的外部目标，但旧标志仍会令它立即取消；快捷键路径会提前清理标志，因此两种入口表现不同。监听现在只使已有目标会话失效，正在进行的粘贴也会取消。
2. 鼠标入口没有执行快捷键入口已有的目标刷新逻辑。Hermes 曾保存 A 应用、用户随后进入 B 应用再用鼠标打开剪贴板时，会继续持有 A 的快照。两个入口现在共用新会话目标准备逻辑；前台已经是外部编辑器时重新捕获，仍在灵动岛内部换页时继续保留原目标。

同一组行为检查对旧源码失败：原源码在“设置关闭后鼠标进入”提交 0 次，只有窗口监听修复时又在“切换外部编辑器后鼠标进入”失败。完整修改后，两种入口均提交到正确的模拟编辑器；会话期间设置窗口取得焦点仍取消，等待权限检查期间取得焦点也取消且不产生迟到反馈。每种情况都检查已写入的回退载荷和面板会话关闭。

`--clipboard-diagnostics` 仅用于受控排查：把阶段、请求编号、进程编号和布尔结果异步写入应用缓存的 `ClipboardDiagnostics/paste-stages.log`，超过 128 KiB 时清空后继续。正常启动不写日志；日志不包含剪贴板正文、AX 值、窗口标题或输入内容。

## 实机日志确认的阻断：XPC 登录会话（2026-10-27）

安装版 9642159 的真实操作日志中，辅助进程已经有 AX 与 PostEvent 权限，也捕获了 Edge 目标与窗口/元素，但连续三次在 `screenLocked` 提前结束，根本未投递 ⌘V。旧代码把 `CGSessionCopyCurrentDictionary() == nil` 等同于锁屏。

Apple 的 [CGSessionCopyCurrentDictionary 文档](https://developer.apple.com/documentation/coregraphics/cgsessioncopycurrentdictionary())说明，调用进程不在 Quartz GUI 会话时会返回 NULL。系统自带 `man 5 xpcservice.plist` 的 `JoinExistingSession` 条目说明：XPC 服务默认创建独立 audit session；设置 true 才加入客户端会话。因此“没有 GUI 会话”和“屏幕已锁定”必须分开。

原生 XPC 对照测试使用同一个沙盒宿主和同一个服务程序，只改变服务配置：默认独立会话拿不到 Quartz 会话；`JoinExistingSession=true` 能拿到。修改前，生产 Info.plist 对照项也失败；修改后，生产配置与显式加入组均通过。测试不打开窗口、不读取剪贴板或用户输入、不发送按键。

针对性修改是服务的 `XPCService.JoinExistingSession=true`，并将缺失会话改成单独的 `sessionUnavailable` 错误：仍禁止投递，但可显示原因。真正锁屏继续取消。沿用 Maccy 的非激活面板、关闭后交接和单次 session 事件，并补齐其本地事件抑制过滤配置；没有增加重复按键或轮流尝试多个 tap。

启动检查现在查询实际打包 helper 的 GUI 会话是否可用，原生 XPC 测试直接加载生产 Info.plist，防止再次只检查权限与 IPC 连通便判定链路可用。Maccy 参考部分的 MIT 署名收录于 `THIRD_PARTY_LICENSES`。

## 验证范围

- `test_clipboard_gui_session.py` 对照默认、显式加入和生产三种 XPC 配置，验证真实 GUI 会话可用性；不发送输入。
- `test_clipboard_native_event.py` 的记录器检查生产事件构造与单一路由。其原生部分只向测试进程自身或 XPC 客户端 PID 投递带标记的事件并立即消费；这些测试不能证明生产 session 路由已被真实编辑器接受。
- `test_clipboard_store.py` 编译运行真实 `ClipboardStore.copy`，只使用临时 history 和独立私有 pasteboard，覆盖原始文本、富文本、图片、文件字节、失败、取消和并发复制。失败 write 的注入不证明系统清空后实际写入失败时能保留旧剪贴板。
- `test_clipboard_session_runtime.py` 执行生产 Store/Presentation 方法，仅在临时源码副本中替换 OS 单例/类型名称。应用、工作区和输入事件由被动适配器提供，设置窗口保持隐藏，操作私有 pasteboard。它验证会话状态管理，不会激活真实应用、读取用户输入、发送按键或请求权限。
- `typecheck_clipboard_presentation.py` 编译生产 Store/Presentation/PermissionController，外部服务为被动 stub；辅助进程同样单独编译检查。

实机结果仍与上述自动检查分开：当前已在专门创建的 TextEdit 测试输入中确认“选择后保留载荷，手动 ⌘V 插入原位置”的回退。电脑控制接口的部分操作会激活应用并触发设置窗口，因此这些受干扰的自动粘贴尝试不能视为正常用户路径的有效验收。旧安装进程的 TCC 日志已确认 AX 和 PostEvent 均允许，不能继续把失败统称为未授权。修复后的实际 session 事件插入、Edge/QQ 和原生快捷键/鼠标入口仍需受控实机验证。

## 连续使用与输入反馈（2026-10-27）

安装版 0efe01b 的阶段日志已出现 `posted`，同时后续选择有 `presented=false` 和交接中途 `cancelled`，因此继续排查主进程会话。新增运行真实 Store/Presentation 的测试，在 helper 等待期间重新送入迟到的可见/隐藏回调；旧版本取消当前动作并无法完成，修改后该动作只提交一次，之后两次新会话也能分别提交。粘贴交接期间，可见性回调不得创建新的鼠标会话。

非激活面板取得键盘不要求整个 NSApplication 激活，故移除以 `didResignActive` 直接结束会话的监听；仍以外部应用切换、窗口关闭、真实外部点击和锁屏为边界。全局点击监视排除本应用实际可交互的面板区域，不把透明窗口包络当成点击区域。设置窗口取得焦点或用户切换目标仍会取消，不能通过缺少快照绕过。

Hermes 每次重新展开产生新的输入会话标识，窗口准入与 SwiftUI 输入焦点都使用该标识，避免快速收起/展开时保留上次“已请求”的状态；快捷键继续使用已有的指定窗口焦点请求，避免多个屏幕的面板互相抢焦点。剪贴板两种入口均可聚焦搜索，搜索字段自身处理导航键，并保留中文输入法组合态。

键盘滚动使用 SwiftUI ScrollGeometry 的实际 visibleRect，以及滚动内容坐标中的行矩形，避免把已滚动的内容偏移当成从零开始的视口。原生隐藏屏幕外测试编译真实 ClipboardDrawer，通过 80 次连续向下/向上选择，逐项确认选中行位于可见区域；它不操作用户输入框、剪贴板、权限或前台焦点。行高亮淡入、回车图标、内容加载指示和底部快捷键提示提供反馈；“减少动态效果”时关闭动画。

这些自动验证不等同于 Edge/QQ 的实际插入验收；按用户要求，安装后的真实交互仍由用户测试。
