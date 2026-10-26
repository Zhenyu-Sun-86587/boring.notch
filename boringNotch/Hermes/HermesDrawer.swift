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

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.turns.isEmpty && store.answer.isEmpty {
                        Text("Hermes").font(.title3.bold())
                        Text("输入问题，或拖入图片、代码与日志。使用 @today / @inbox 引用本地便签。")
                            .foregroundStyle(.secondary)
                        if IslandSettings.string("hermesURL").isEmpty {
                            Button("Configure Hermes & Todo…") { SettingsWindowController.shared.showIslandSettings() }
                        }
                    }
                    ForEach(Array(store.turns.enumerated()), id: \.offset) { _, turn in
                        Text(turn.prompt).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        richText(turn.assistant)
                    }
                    if !store.answer.isEmpty && (store.isGenerating || store.turns.last?.assistant != store.answer) {
                        richText(store.answer)
                    }
                    if store.isGenerating { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
            if !store.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(store.attachments) { item in
                            HStack(spacing: 5) {
                                Image(systemName: "paperclip")
                                Text(item.url.lastPathComponent).lineLimit(1)
                                Button { store.remove(item) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).disabled(store.isGenerating)
                            }
                            .font(.caption).padding(6).background(.white.opacity(0.08), in: Capsule())
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            if !SurfaceFiles.references(in: store.input).isEmpty {
                Text("上下文：" + SurfaceFiles.references(in: store.input).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                    .help("发送时读取最新文件。目录变化：\(surface.revision.uuidString)")
            }
            if let message = store.message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack(alignment: .bottom) {
                TextField("Ask Hermes…", text: $store.input, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.plain).focused($inputFocused)
                    .onSubmit { store.send() }
                    .onKeyPress(.return, phases: .down) { key in
                        let composing = (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
                        guard !key.modifiers.contains(.shift), !composing else { return .ignored }
                        store.send()
                        return .handled
                    }
                    .disabled(store.isGenerating)
                if store.isGenerating {
                    Button("Stop", systemImage: "stop.fill") { store.stop() }.labelStyle(.iconOnly)
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") { store.send() }
                        .labelStyle(.iconOnly).disabled(store.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isPreparingDrop)
                }
            }
            .padding(10).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 16) {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.answer, forType: .string)
                }.disabled(store.answer.isEmpty)
                Button("存入待办", systemImage: "checklist") { store.saveAnswer() }
                    .disabled(store.answer.isEmpty || store.isGenerating)
                Button("Clear", systemImage: "trash") { store.clear() }
                Spacer()
                Button("Settings", systemImage: "gear") { SettingsWindowController.shared.showIslandSettings() }
                    .labelStyle(.iconOnly)
                Button(store.isWide ? "Compact" : "Wide", systemImage: "arrow.left.and.right") { store.isWide.toggle() }
            }
            .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: 2).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL, .image, .plainText], isTargeted: $dropTarget) { providers in
            store.stage(providers); return true
        }
        .onAppear {
            store.appeared(vm.screenUUID ?? "primary")
            Task { @MainActor in
                await Task.yield()
                inputFocused = true
            }
        }
        .onDisappear {
            inputFocused = false
            store.disappeared(vm.screenUUID ?? "primary")
        }
        .onChange(of: store.isGenerating) { _, generating in
            if !generating { inputFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandLocked)) { _ in inputFocused = false; store.stop() }
    }

    private func richText(_ text: String) -> some View {
        StructuredText(markdown: text, syntaxExtensions: [.math])
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
                Text("Code").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    configuration.codeBlock.copyToPasteboard()
                }.buttonStyle(.plain).font(.caption)
            }
            ScrollView(.horizontal) { configuration.label.fixedSize(horizontal: true, vertical: false) }
        }
        .padding(8).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
