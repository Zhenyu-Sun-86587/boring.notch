# Hermes 与剪贴板交互调试

设置 → 通用 → 交互调试，或设置 → 剪贴板 → 交互调试，使用同一个“记录详细调试日志”开关。默认关闭，立即生效，不需要重启。

1. 打开开关，点击“清空日志”，开始一次新的复现。
2. 从目标应用的输入框打开灵动岛，分别复现 Hermes 自动焦点、手动点击输入、剪贴板点击／回车；尽量保留一次成功和随后失败的对照。
3. 回到设置，关闭开关停止记录，然后点击“导出日志…”。文件是 UTF-8 文本，每行一个 JSON 对象；也可点击“显示日志文件夹”。

不会记录输入正文、剪贴板正文或图片、便签内容、窗口标题、文件路径、API 地址、请求头或密钥。只记录本应用的控制键（上下、回车、Esc）、本应用窗口内鼠标位置、进程和窗口编号、应用／响应者类型、布尔状态、请求编号及取消原因。不会全局监听键盘字母。

日志包含时间、递增序号、运行编号、版本／构建和系统版本。当前文件与上一文件各限制 2 MiB，待写队列也有上限；关闭后不编码或写入事件。日志保存在应用缓存的 InteractionDiagnostics 目录，清空只删除这两个日志，不修改历史或配置。导出是手动操作，不自动上传。

## 从真实事件定位

- `window/input-delivered`：事件是否进入本应用窗口。鼠标事件包含位置；键盘只记录允许的控制键编号。
- `focus.field/pointer-received`：点击是否命中 Hermes 输入框或剪贴板搜索框的原生区域，输入框观察器不参与命中测试；主按键点击现在向同一个窗口桥发送明确焦点请求，仍等待外部目标捕获。
- `focus.bridge`：窗口请求、目标快照等待、交接拦截、准入跳过，以及 makeKey 前后状态。
- `focus.input/decision`：明确记录 drawer-closed、inactive-tab、window-not-key、input-hidden、locked、handoff、blocking-ui 或 allowed。
- `hermes.input/focus-state` 和 `focus.input/responder-after`：SwiftUI 焦点绑定与下一次运行循环的实际响应者；绑定变成 true 本身不证明已能输入。
- `clipboard.input`：控制键是否进入 SwiftUI 处理器、行命中、点击释放是否激活；不记录搜索字符串。
- `clipboard.store`：是否存在选择、busy/pasting 门禁、载荷准备、剪贴板写入及会话结束；不记录内容。
- `clipboard.presentation`：可见性、目标捕获、会话清理、选择拒绝、交接和取消。每个事件均带会话及当前请求编号。
- `clipboard.helper/request-trace`：同一请求编号下，辅助进程观测到的前台／焦点 PID、AX 判断、输入按钮释放、锁屏／GUI 会话、稳定等待和单次事件投递结果。仅开启时通过 XPC 回传，辅助进程不另写日志。

辅助进程的 `foreground` 现在来自系统级 `AXFocusedApplication` 实时查询，最终按键投递也使用同一查询；`workspace` 仅作诊断对照，不参与授权或目标判断。实际日志曾连续出现主程序与 AX 焦点均指向 Edge，而 XPC 的 `NSWorkspace.frontmostApplication` 固定返回已退出的旧 PID，导致在 0–1 ms 内误报 `focusChanged`。不能通过延迟、重试按键或放宽目标校验来修复这种缓存过期。实时查询失败保持未知，不使用记忆中的应用发送全局按键；真正切换应用、输入位置变化或剪贴板更新仍取消自动粘贴。

若日志同时出现 `ax=true post=true gui=true`、`match=matched inputReady=true`，但 `foreground=nil focused=nil` 并在约 1.8 秒后返回 `focusUnavailable`，需检查辅助进程的 AppKit 初始化。原生 XPC 对照已证实：仅 `JoinExistingSession=true` 和 XPC listener 的运行循环不足以建立 AppKit 的 WindowServer 连接；未初始化时系统级 AX 返回 `cannotComplete (-25204)`，而单个应用的 AX 属性仍可正常读取。辅助进程入口现在先调用 `ClipboardHelperRuntime.prepare()`，以禁止激活的策略初始化 `NSApplication.shared`，再接受连接。`.github/scripts/test_clipboard_runtime.py` 使用真实签名的沙盒宿主与 XPC 服务，在同一辅助进程内对比初始化前后，只采集 API 错误码、PID 和运行状态，不读取输入元素、标题或剪贴板，也不发送事件、请求权限或激活窗口。测试需区分实际复现、无既有授权时跳过和当前焦点不可观测的情况。

`posted` 只表示提交了按键，不表示目标编辑器已经消费内容。自动化测试只能确认记录器、协议、隔离会话与布局；Hermes 实际输入和 Edge／QQ 实际粘贴仍须根据复现日志定位。本次主要交付诊断能力，不宣称两个故障已经解决。

## 2026-10-27 鼠标入口与粘贴收起修复

本机本轮日志共748条，鼠标失败和快捷键成功在同一运行、同一 Edge PID 下对照：

- 鼠标路径12–28：真实 drawer-visible 和 row-pointer 命中，却没有 session-begin；窗口桥的全局鼠标准入为false，选择最终 `presented=false` 拒绝。
- 快捷键路径169–226：先建立会话，窗口可成为key，辅助进程单次session事件为posted。
- Hermes路径704–731：抽屉打开、目标捕获完成，窗口桥再次判全局位置不在窗口；手动点击到达输入框并使SwiftUI绑定为true，窗口仍 `canKey=false / windowKey=false`，键盘继续给原应用。

根因是鼠标入口已有真实窗口悬停事件，却再次查询全局鼠标位置来分别决定窗口准入和剪贴板会话。改为按ContentView实际收到的即时悬停状态准入窗口，按同一屏幕的pointerChanged事件建立剪贴板会话；不依赖重新读取的全局位置。延迟到达的hover也能启动已经显示的抽屉。输入框主键点击通过同一个窗口桥明确请求焦点，不直接绕过锁屏、目标捕获或其他窗口竞争保护。

回归检查将全局鼠标故意设为屏幕外，同时发送真实入口对应的hover状态：旧生产方法失败，新方法通过，并覆盖延迟hover、连续会话、目标变化和设置竞争。原生窗口桥测试也单独验证hover在目标准备好后获得准入，没有激活用户应用。

自动粘贴过去把整个面板隐藏到异步辅助进程返回，导致SwiftUI收起动画在不可见期间前进，然后中途重新显示。现在通过与普通关闭相同的同步orderOut/orderFront释放键盘，保留可见窗口连续收起；实际helper仍等原应用焦点稳定、按键松开和剪贴板版本一致后单次投递。移除持久suspendedPanels和异步恢复路径。屏幕外实际SwiftUI动画检查覆盖paste-close每个采样点仍可见、中间高度连续；生产Store/Presentation检查确保没有跨异步helper等待的隐藏租约。

安装后的真实鼠标交互和视觉效果仍以用户验收及新日志为准；posted不作为插入成功凭证。
