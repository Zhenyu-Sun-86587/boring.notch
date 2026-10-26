import AppKit
import SwiftUI
import Textual
import IslandCore

struct HermesDrawer: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var store = HermesStore.shared
    @ObservedObject private var surface = SurfaceAccess.shared
    @FocusState private var inputFocused: Bool
    @State private var dropTarget = false
    @State private var showingWidthControls = false
    @State private var drawerVisible = false

    var body: some View {
        VStack(spacing: 8) {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if store.turns.isEmpty && store.answer.isEmpty && IslandSettings.string("hermesURL").isEmpty {
                            Button("配置 Hermes", systemImage: "gearshape") {
                                SettingsWindowController.shared.showIslandSettings()
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                        ForEach(store.turns) { turn in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(turn.prompt).font(.callout).textSelection(.enabled)
                                    .padding(10).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                if !turn.assistant.isEmpty { richText(turn.assistant) }
                                submissionStatus(turn)
                            }
                            .id(turn.id)
                        }
                        if store.isPreparingRequest {
                            ProgressView("正在准备…").controlSize(.small).font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
                .onChange(of: store.turns.last?.id) { _, id in
                    if let id { scroll.scrollTo(id, anchor: .bottom) }
                }
            }
            if !store.attachments.isEmpty || store.includesNote {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        if store.includesNote {
                            attachmentChip(name: surface.fileName, icon: "doc.text", removeLabel: "取消引用便签") {
                                store.includesNote = false
                            }
                            .help(surface.filePath)
                        }
                        ForEach(store.attachments) { item in
                            attachmentChip(name: item.url.lastPathComponent, icon: "paperclip", removeLabel: "移除附件") {
                                store.remove(item)
                            }
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            if let message = store.message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("输入消息…", text: $store.input, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.plain).focused($inputFocused)
                    .onSubmit { store.send() }
                    .onKeyPress(.return, phases: .down) { key in
                        let composing = (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
                        guard !key.modifiers.contains(.shift), !composing else { return .ignored }
                        store.send()
                        return .handled
                    }
                if store.isGenerating {
                    Button("停止", systemImage: "stop.fill") { store.stop() }
                        .labelStyle(.iconOnly).help("停止生成")
                } else {
                    Button("发送", systemImage: "arrow.up.circle.fill") { store.send() }
                        .labelStyle(.iconOnly).help("发送")
                        .disabled(store.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isPreparingDrop)
                }
            }
            .padding(12).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 16) {
                Button("复制", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.answer, forType: .string)
                }.disabled(store.answer.isEmpty)
                Button("保存到便签", systemImage: "square.and.arrow.down") { store.saveAnswer() }
                    .disabled(store.answer.isEmpty || store.isGenerating || store.isSaving || !surface.hasFile)
                Button("清空", systemImage: "trash") { store.clear() }
                Spacer()
                Button("引用便签", systemImage: store.includesNote ? "doc.text.fill" : "doc.text") {
                    if !surface.hasFile {
                        vm.isPopoverActive = true
                        surface.chooseFile()
                        vm.isPopoverActive = false
                    }
                    if surface.hasFile { store.includesNote.toggle() }
                }
                .labelStyle(.iconOnly).help("引用便签").disabled(store.isGenerating)
                Button("设置", systemImage: "gearshape") { SettingsWindowController.shared.showIslandSettings() }
                    .labelStyle(.iconOnly).help("设置")
                Menu {
                    Button(store.isWide ? "收窄" : "展宽") { store.isWide.toggle() }
                    Button("调整宽度…") { showingWidthControls = true }
                } label: {
                    Image(systemName: "arrow.left.and.right")
                }
                .menuStyle(.borderlessButton).fixedSize().help("调整宽度")
                .popover(isPresented: $showingWidthControls) {
                    HermesWidthControls().padding(16).frame(width: 320)
                }
            }
            .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
        .background(HermesInputFocusObserver(enabled: shouldFocusInput, isCurrent: { shouldFocusInput }) { focused in
            if inputFocused != focused { inputFocused = focused }
        })
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: 2).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL, .image, .plainText], isTargeted: $dropTarget) { providers in
            vm.dropInteraction.dropEvent = true
            store.stage(providers)
            return true
        }
        .onChange(of: dropTarget) { _, targeted in vm.dropInteraction.dropZoneTargeting = targeted }
        .onChange(of: showingWidthControls) { _, showing in vm.isPopoverActive = showing }
        .onChange(of: surface.hasFile) { _, hasFile in if !hasFile { store.includesNote = false } }
        .onAppear {
            drawerVisible = true
            store.appeared(vm.screenUUID ?? "primary")
        }
        .onDisappear {
            drawerVisible = false
            inputFocused = false
            vm.dropInteraction.dropZoneTargeting = false
            store.disappeared(vm.screenUUID ?? "primary")
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandLocked)) { _ in inputFocused = false }
    }

    private var shouldFocusInput: Bool {
        drawerVisible && vm.notchState == .open && BoringViewCoordinator.shared.currentView == .hermes
            && !vm.isPopoverActive && !showingWidthControls
    }

    @ViewBuilder
    private func submissionStatus(_ turn: HermesTranscript.Turn) -> some View {
        switch turn.status {
        case .thinking:
            ProgressView("正在思考…").controlSize(.small).font(.caption)
        case .responding:
            ProgressView("正在生成…").controlSize(.small).font(.caption)
        case .failed(let error):
            HStack(alignment: .top) {
                Text("生成失败：\(error)").textSelection(.enabled)
                if store.canRetry(turn.id) { Button("重试") { store.retry(turn.id) } }
            }.font(.caption).foregroundStyle(.secondary)
        case .stopped:
            HStack {
                Text("已停止")
                if store.canRetry(turn.id) { Button("重试") { store.retry(turn.id) } }
            }.font(.caption).foregroundStyle(.secondary)
        case .completed: EmptyView()
        }
    }

    private func attachmentChip(name: String, icon: String, removeLabel: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(name).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .accessibilityLabel(removeLabel)
                .buttonStyle(.plain).disabled(store.isGenerating)
        }
        .font(.caption).padding(6).background(.white.opacity(0.08), in: Capsule())
    }

    private func richText(_ text: String) -> some View {
        StructuredText(text, parser: HermesMarkdownParser())
            .textual.textSelection(.enabled)
            .textual.structuredTextStyle(.gitHub)
            .textual.codeBlockStyle(HermesCodeBlockStyle())
            .font(.system(size: 13))
    }
}

struct HermesCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("代码").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("复制") { configuration.codeBlock.copyToPasteboard() }
                    .buttonStyle(.plain).font(.caption)
            }
            ScrollView(.horizontal) { configuration.label.fixedSize(horizontal: true, vertical: false) }
        }
        .padding(8).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
