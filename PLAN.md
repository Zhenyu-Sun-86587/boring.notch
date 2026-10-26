> 2026-10-26 范围更新：用户确认改用上游 v2.8-rc.2；待办恢复原生 macOS 日历与提醒事项，移除 Vikunja 直连；Hermes 使用单个任意名称的 Markdown 文件，支持自定义宽度；新增快捷键与灵动岛共用的剪贴板历史并保留图片原始数据。以下为最初方案，当前配置与验收以 [docs/Hermes.md](docs/Hermes.md) 为准。

# Boring Notch 二开功能需求与架构方案 (PLAN.md)

> **目标受众**：Codex CLI (GPT-6.1-sol)  
> **工程定位**：面向 macOS 27 的端侧灵动岛智能体驾驶舱与通用待办中枢  
> **仓库地址**：`Zhenyu-Sun-86587/boring.notch` (Fork 自 `TheBoredTeam/boring.notch`)  
> **指导思想**：**需求与约束明确，具体实现由 Codex 自主架构决策**。请基于以下业务场景与非功能性约束，自行设计最优雅、高性能且符合 Swift 6 / SwiftUI 规范的实现方案。

---

## 一、 运行环境与编译交付约束

1. **目标系统架构**：
   - 目标系统为 **macOS 27 (Golden Gate)**，100% 独占 **Apple Silicon (ARM64)** 架构。
   - 适配 Liquid Glass 2.0 高对比度暗色主题与 macOS 27 SkyLight 悬浮窗口规范。

2. **编译与交付链（无本地 Xcode 约束）**：
   - **本地环境无 Xcode 工具链**，无法在宿主机直接执行 `xcodebuild`。
   - **必须配置 GitHub Actions 云端编译流水线**（如 `.github/workflows/build-adhoc.yml`），由 `macos-latest` (或指定 macOS Runner) 执行编译打包。
   - **代码签名规约**：采用 **Ad-hoc 本地临时自签**（`CODE_SIGN_IDENTITY="-"`，`CODE_SIGNING_REQUIRED=NO`），不得强依赖付费 Apple Developer ID 证书私钥（Secrets）。编译完成后以 GitHub Release / Artifact 产物形式输出带执行权限的 `Boring Notch.app.zip`。

3. **代码隔离与上游兼容（Fork 规范）**：
   - 保持与上游 `TheBoredTeam/boring.notch` 的最大兼容性，原工程既有功能（音乐控制、电量状态、OSD、Shelf）**全量保留，不做破坏性删除**。
   - 二开增量模块统一收敛至独立目录（如 `boringNotch/Hermes/` 及 `boringNotch/Todo/`），原工程公共文件仅作最小切口挂载（Mount Point），以便后续通过 `git merge upstream/main` 平滑对齐上游更新。

---

## 二、 核心功能需求 (Functional Requirements)

### 1. Hermes 智能体闪击抽屉 (Hermes Island Drawer)
* **顶栏入口与挂载**：
  - 在展开态顶部的 `TabSelectionView` 中，与现有 `Home`、`Shelf` 并列新增专属于 `Hermes` 的 Tab 胶囊入口。
* **纯鼠标悬停流交互**：
  - 核心唤醒方式为**鼠标悬停展开（Hover-to-Expand）**，鼠标滑出抽屉区域在缓冲延迟后自动平滑收缩（Auto-Collapse）。
  - 展开或切至该 Tab 时，输入框自动捕获键盘焦点（`@FocusState`），用户无需二次点击即可盲打输入。
* **流式问答通信**：
  - 通过 Tailscale 私网直连远端 Hermes OpenAI 兼容网关（端点 `POST http://100.73.30.59:8642/v1/chat/completions`，支持自定义 Host/Key）。
  - 基于 `URLSession.bytes` 消费 SSE (`stream: true`) 数据流，呈现打字机输出效果。
* **动态自适应宽度 (Dynamic Auto-Wider)**：
  - 展开面板支持向两侧对称弹性延伸（基于 SwiftUI Spring 阻尼动效）。
  - **紧凑态**（默认 ~640px）：适合简答与纯文本；
  - **宽屏态**（~920px+）：当检测到输出中包含 Markdown 表格（`|---|`）、长代码围栏（` ``` `）或用户主动切换时，向两侧平滑展宽，彻底避免横向拥挤；支持单行代码横向平滑滚动与独立复制。
* **丰富文本渲染 (Markdown / LaTeX)**：
  - 保证 Markdown 结构、表格、数学公式（LaTeX `$E=mc^2$`, `$$\sum$$`）完整渲染，排版整洁利落。
* **快捷动作条 (Sticky Action Bar)**：
  - 面板底部固定操作区：包含一键复制全文、一键沉淀至本地待办、清除会话上下文。

### 2. 标准通用待办与日历联动 (Universal Todo / Vikunja)
* **彻底脱离 Apple 专有生态**：
  - **禁用 / 替换 Apple EventKit (`EKEventStore`)**，消除对 macOS 原生“日历与提醒事项”的 TCC 权限强依赖与弹窗骚扰。
* **对接通用标准待办源**：
  - 将原工程中的 `CalendarServiceProviding` 抽象解耦，对接标准通用协议服务源（优先对接自建 **Vikunja REST API** 或 **CalDAV** 端点 `https://todo.adcdxc.me/dav/`，或读取本地同步待办）。
  - **功能要求**：
    1. 拉取待办清单与截止期日程，呈现在 Notch 时间轴；
    2. 支持在 Notch 面板中直接勾选完成任务，状态双向同步至服务端；
    3. 待办真理源过滤：严格排除副本池（如 Project 3 投影），以实体工程项目为准。

### 3. 拖拽暂存区多模态投喂 (Staging & Vision Context)
* 复用现有 `Shelf` 的拖放捕获管道，支持向灵动岛拖入截图、图片或代码文本。
* 暂存区在输入框上方生成可移除的标签胶囊（Chips）；
* 组装请求时，自动分流处理：图片压缩转换为多模态 Base64 (`image_url`)，文本/日志文件自动以 Markdown 附件形式拼入上下文。

### 4. 本地 Markdown 双向联动 (HermesSurface / Today.md)
* **输入联动**：输入框支持 `@today` / `@inbox` 标记语法，检测到后静默读取本地便签目录（`~/Sync/HermesSurface/Today.md` 或 `Inbox.md`）作为上下文注入 Prompt。
* **输出沉淀**：回答底部的“存入待办”动作，直接在本地 `Today.md` 尾部追加 `- [ ] <任务内容>`，依托本地文件系统热监听触发全桌面刷新。

---

## 三、 非功能性约束与性能治理 (Performance & Resource Guards)

> **极客底线：灵动岛是一个 7x24 小时后台常驻工具，绝不能成为内存与 CPU 刺客！**

1. **常驻内存硬指标**：
   - **后台闲置/切歌态**：整机常驻内存必须严密控制在 **< 50MB**；
   - **问答激活态**：简单文本峰值控制在 **< 80MB**；若调动外部渲染引擎，闲置超时后必须**彻底冷释放**，回落至基准线。
2. **渲染架构防爆设计**：
   - 避免无节制全天候常驻重型 WebKit / GPU 辅助进程；
   - 建议采取双轨制或惰性生命周期管理（纯文本走极轻原生渲染，仅在复杂排版时按需加载透明微沙盒并在关闭后及时回收）。
3. **图像与大文件零内存驻留**：
   - 暂存区只持有本地文件 `URL` 路径指针，严禁持有未经缩放的 4K 位图到内存；
   - 预览缩略图必须通过硬件下采样（如 ImageIO `CGImageSourceCreateThumbnailAtIndex`）生成极小位图；发送时在 `autoreleasepool` 内读写，发送完毕物理释放。
4. **会话生命周期与内存环形缓冲**：
   - 内存中的上下文消息队列实行严格的 FIFO 定长环形缓冲（限制 6~8 轮），超时（如关闭抽屉超过 15 分钟）自动失效重置，杜绝长文本内存泄露与上下文污染。

---

## 四、 交付与执行验收标准

- [ ] **代码结构**：新增源码置于独立目录，最小化修改原工程，构建无 warning/error；
- [ ] **CI 流水线**：提供健全的 `.github/workflows/build-adhoc.yml`，能在 GitHub Actions 上单触发编译出签发后的 `.app.zip`；
- [ ] **功能验收**：
  1. 悬停触碰展开，可在顶栏一键切换至 Hermes 标签页；
  2. 支持流式打印输出，遇长代码/表格自适应展宽（~920px）；
  3. 日历模块成功脱离 Apple EventKit，直连 Vikunja / 通用 Todo 并支持原位打勾；
  4. 支持拖拽图片暂存投喂多模态，支持 `@today` 读取与一键追加本地便签；
- [ ] **性能验收**：后台常驻内存指标健康，无 CPU 空转。
