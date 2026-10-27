# 高标签退出时的顶部缝隙：根因与验证

问题发生在 Hermes／剪贴板等高标签切回主页／暂存区，或高标签直接收起时。只有高标签取得键盘焦点；退出时需要释放非激活面板的键盘所有权，会调用 `orderOut`，再恢复窗口可见性。短标签之间的切换没有这一步。

## 根因

`BoringNotchSkyLightWindow` 原来保留 AppKit 默认的 `animationBehavior`。窗口隐藏／恢复时，AppKit 会自行选择窗口动画，与窗口内部已经存在的 SwiftUI 伸缩动画同时发生。最终屏幕会出现临时位移；原窗口的 frame、宿主布局和内容源没有这个位移，因此读取原窗口坐标或单独捕获窗口内容都无法复现可见缝隙。

[Apple 文档](https://developer.apple.com/documentation/appkit/nswindow/animationbehavior-swift.property)明确说明该属性控制 `orderFront`／`orderOut` 的自动窗口动画，应用已有自定义动画时可以设置 `.none`。[IINA 的 NSPanel 社区排查](https://github.com/iina/iina/issues/6143)也记录了开发者因本机自动窗口动画设置不同而无法复现的情况。

正式修改只在灵动岛窗口的配置中设置 `animationBehavior = .none`，保留内容内部的 SwiftUI 伸缩、阴影和圆角动画，以及原有键盘交接。设置窗口的系统动画不受影响。

## 实机证据（2026-10-27）

用户先在 `dc23f2c` 和 `65d4dac` 稳定复现，并确认缝隙中露出桌面。两个版本的原窗口、宿主和外壳布局始终贴顶，WindowServer 基础矩阵也没有变化。给轮廓和内容添加 `geometryGroup()` 未消除故障，已经撤回。

随后使用 ScreenCaptureKit 只计算屏幕顶部的黑色边界位置，不保存画面、输入内容或音频：

- 原状态：2396 帧中捕获 10 次缝隙、76 个异常帧；最大下移 5.5 点，每次约 102–172 毫秒。
- 同一 `65d4dac` 二进制，单次启动传入 `-NSAutomaticWindowAnimationsEnabled NO`：2194 帧中异常帧为 0；用户确认缝隙消失。
- 此启动参数只用于单变量诊断，没有修改 macOS 全局偏好。正式版本使用窗口级公开 API，不需要保留该参数。

以上对照确认了自动窗口动画这条路径。正式窗口级配置仍需安装后的相同操作验收，不能以隔离测试代替用户的实机结果。

## 清理与回归边界

临时几何日志、计时器、进程参数入口及 WindowServer 变换读取已经从应用移除；临时采样工具只保留在本地构建证据中。顶部像素回归同时检查两侧与中心，避免中心黑色刘海掩盖背景变化。

离屏组件／窗口测试继续覆盖顶部对齐、换页、阴影和输入布局，但它们不能独自证明 AppKit 最终屏幕动画无误。实际屏幕边界采样和用户对照结果是本次根因判断的关键证据。


## 截图软件选中透明窗口（2026-10-27）

用户照片中 Snipaste 选区为 952×572；对已安装版读取自身 CGWindow 元数据，闭合面板确实仍为 952×572、layer 27、alpha 1、顶部 y=0。
鼠标穿透只影响命中测试，不能改变第三方按 WindowServer 边界识别窗口的行为。Snipaste 官方高级配置中的 exclude_from_detection 标注 Windows ONLY，不能当作本机 macOS 修复。

修复将两种边界分离：NotchHostingContainer 固定 SwiftUI 画布的尺寸并始终顶端居中；IslandFittedWindow 在外层交易中等待 `.removed` 动画完成，再让系统窗口贴合实际表面及阴影/悬停边距。动画期间先扩展物理窗口，目标改变后以 generation 丢弃旧完成回调。所有 frame 写入仍异步执行，保留 animationBehavior.none。
只在内部子视图注册完成回调不能覆盖外壳自己的动画，因此生命周期必须包住整个根视图。屏幕重定位保留当前窗口尺寸，不把已经收缩的窗口重置成最大画布。

自动检查使用生产窗口桥、宿主和外壳，以离屏窗口验证高→短、完全关闭、反向展开、粘贴回缩、无动画及透明命中穿透。测试中内部画布保持 952×572，闭合系统窗口收为 217×58，并核对自身 CGWindow 元数据。其他实际尺寸会随设备刘海、内容、悬停区及用户宽度设置变化。没有读取用户窗口像素或发送输入。

参考：
- Apple Transaction.addAnimationCompletion： https://developer.apple.com/documentation/swiftui/transaction/addanimationcompletion(criteria:_:)
- Snipaste 高级配置平台限制： https://github.com/Snipaste/feedback/wiki/Advanced-Configs
- 社区同类窗口检测报告（不同进程，不能代替本机证据）： https://github.com/Snipaste/feedback/issues/3795
