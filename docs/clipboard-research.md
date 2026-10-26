# 自动粘贴实现与验证

核对日期：2026-10-27。以下是源码和社区证据；它们不能替代本应用在 Edge、QQ 等实际输入框中的验收。

## 参考实现

- [Maccy Clipboard.swift（7c1644b）](https://github.com/p0deje/Maccy/blob/7c1644bfbed1dd0d703ecdbaf4a1b9a3a1d0b295/Maccy/Clipboard.swift#L122-L148)：通过 `combinedSessionState` 构造快捷键，发到 `cgSessionEventTap`。其 [History 动作](https://github.com/p0deje/Maccy/blob/7c1644bfbed1dd0d703ecdbaf4a1b9a3a1d0b295/Maccy/Observables/History.swift#L354-L372)先关闭非激活面板，再复制、粘贴。
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

## 验证范围

`test_clipboard_native_event.py` 首先使用注入的记录器验证生产事件构造、单一路由和前台切换取消，完全不投递系统会话事件。随后两项原生测试仅向无窗口测试进程自身或 XPC 客户端 PID 投递带标记的事件，收到后立即消费；它们仅验证隔离的定向传输。测试构建通过编译标记禁用默认 session 投递，避免误调用影响用户。

上述原生定向传输是既有脚本的范围说明，本轮未运行 `test_clipboard_native_event.py`，也未发送任何真实 CGEvent。只单独运行其 `ClipboardPasteEventChecks` 的注入记录器，用生产构造函数验证一对事件和单一 session 路由。

本轮新增 `test_clipboard_store.py` 编译并运行真实 `ClipboardStore.copy`，只使用临时 history 和独立命名的私有 pasteboard，验证文本/富文本/图片/文件原字节、先复制后请求、复制失败、会话结束/新会话/锁屏、载荷迟到错误和并发新复制的取消。失败 write 的注入仅证明不报告复制/粘贴成功，不证明系统 `clearContents` 后实际写入失败能保留旧剪贴板。`typecheck_clipboard_presentation.py` 只编译生产 Store/Presentation/PermissionController，所有外部依赖均为被动 stub；实际 helper/Shared 同样单独 typecheck。

本轮剪贴板验证没有访问用户 general 剪贴板、AX 输入树、权限状态、真实输入或可见窗口，也没有启动、安装应用；并行的窗口布局测试有独立授权与验证边界。生产 Presentation/helper 的 nil/过期 token 应用级路径目前由静态审查和编译覆盖；真实 session 路由在 Edge、QQ 等应用中的输入行为，以及权限变更后的系统表现，仍由用户实机验收。
