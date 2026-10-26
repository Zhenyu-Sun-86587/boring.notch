# 自动粘贴实现与验证

核对日期：2026-10-26。以下是源码和社区证据；它们不能替代本应用在 Edge、QQ 等实际输入框中的验收。

## 参考实现

- [Maccy Clipboard.swift（7c1644b）](https://github.com/p0deje/Maccy/blob/7c1644bfbed1dd0d703ecdbaf4a1b9a3a1d0b295/Maccy/Clipboard.swift#L122-L148)：通过 `combinedSessionState` 构造快捷键，发到 `cgSessionEventTap`。其 [History 动作](https://github.com/p0deje/Maccy/blob/7c1644bfbed1dd0d703ecdbaf4a1b9a3a1d0b295/Maccy/Observables/History.swift#L354-L372)先关闭非激活面板，再复制、粘贴。
- [Clipy PasteService（e68ccf4）](https://github.com/Clipy/Clipy/blob/e68ccf48cefec2fd77d1cec48c5ea079fbf60858/Clipy/Sources/Services/PasteService.swift#L128-L154)：先检查辅助功能权限，再异步发送一对快捷键到 annotated session tap。
- [CopyQ macplatformwindow（d39e44c）](https://github.com/hluk/CopyQ/blob/d39e44c3853a8aa05a77073e3d8e48d29cddb043/src/platform/mac/macplatformwindow.mm#L120-L143)：让出运行循环，等待目标窗口恢复焦点，再发送快捷键。
- [Copyosity paste.rs（aad3c2b）](https://github.com/vakovalskii/copyosity/blob/aad3c2bd6c6a4fd9fdedc935ab019f8a4bb1fdcc/src-tauri/src/clipboard_macos/paste.rs#L147-L158)：目标位于前台时使用 session tap；源码记录部分原生应用忽略 `postToPid`，同时发送多个 tap 会造成重复粘贴。其[目标记忆](https://github.com/vakovalskii/copyosity/blob/aad3c2bd6c6a4fd9fdedc935ab019f8a4bb1fdcc/src-tauri/src/clipboard_macos/mod.rs#L273-L340)在自身面板获取焦点前保存外部应用，并记录最近的外部激活应用。

## 本次选择

自动粘贴采用 `combinedSessionState` 与单次 `cgSessionEventTap`。辅助进程先检查权限、目标输入位置、锁屏、按键释放及剪贴板版本；事件发送器在构造事件前后确认目标 PID 仍在前台。按下和抬起在同一次同步调用里发送，不并行投递多个路径，也不在发送后自动重试。

不使用鼠标点击猜测输入框，不使用 AppleScript 兜底。`CGEvent` 投递没有编辑器消费确认：函数成功仅表示已提交事件，不能显示成“已确认插入”。

## 权限与提示框

- [Maccy #1381](https://github.com/p0deje/Maccy/issues/1381)报告自编译版本只复制不粘贴，社区通过重新加入辅助功能列表恢复；[CopyQ #1030](https://github.com/hluk/CopyQ/issues/1030)记录开关仍存在但授权失效的相似情况。这些属于社区个案，不证明所有粘贴失败都由授权导致。
- [Apple AXIsProcessTrusted](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted)检查当前执行进程。主程序或命令行测试的授权结果不能代替实际发事件的 helper 状态。Ad-hoc 构建的签名身份依赖代码哈希，更新后可能需要使用者重新授权；应用不自动授予或重置权限。
- [Apple NSAlert.layout](https://developer.apple.com/documentation/appkit/nsalert/layout())提供立即排版。独立展示 `NSAlert.window` 前完成排版，避免模板抑制框、空按钮和截断文字。
- [Apple XPC 服务指南](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html)说明服务可能被终止和重启；辅助进程中的临时焦点引用必须按会话有效性处理，不能将内存 token 当成持久状态。

## 验证范围

`test_clipboard_native_event.py` 首先使用注入的记录器验证生产事件构造、单一路由和前台切换取消，完全不投递系统会话事件。随后两项原生测试仅向无窗口测试进程自身或 XPC 客户端 PID 投递带标记的事件，收到后立即消费；它们仅验证隔离的定向传输。测试构建通过编译标记禁用默认 session 投递，避免误调用影响用户。

测试不读取剪贴板内容或 AX 输入树，不激活窗口，也不请求权限。已有授权不足时，原生定向传输明确记录跳过。真实 session 路由在 Edge、QQ 等应用中的输入行为，以及权限变更后的系统表现，仍由用户实机验收。
