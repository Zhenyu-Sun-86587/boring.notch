import AppKit
import IslandCore
import SwiftUI

struct ClipboardDrawer: View {
    @ObservedObject private var store = ClipboardStore.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索剪贴板", text: $store.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onKeyPress(.downArrow, phases: .down) { _ in
                        guard !isComposing else { return .ignored }
                        store.moveSelection(1); return .handled
                    }
                    .onKeyPress(.upArrow, phases: .down) { _ in
                        guard !isComposing else { return .ignored }
                        store.moveSelection(-1); return .handled
                    }
                    .onKeyPress(.return, phases: .down) { key in
                        guard !isComposing else { return .ignored }
                        store.copySelected(paste: !key.modifiers.contains(.command)); return .handled
                    }
                if !store.search.isEmpty {
                    Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("清空搜索")
                }
            }
            .padding(10)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

            if !store.enabled {
                HStack {
                    Button("启用剪贴板历史") { store.requestReadAccess() }
                    Spacer()
                }.font(.caption)
            } else if store.readDenied {
                HStack {
                    Button("允许剪贴板访问") { store.openReadSettings() }
                    Spacer()
                }.font(.caption)
            } else if store.needsReadAccess {
                HStack {
                    Button("允许读取剪贴板") { store.requestReadAccess() }
                    Spacer()
                }.font(.caption)
            }
            if store.filteredRecords.isEmpty {
                Spacer()
                Text(store.search.isEmpty ? "暂无记录" : "没有匹配的记录")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(store.filteredRecords) { record in
                                ClipboardHistoryRow(record: record, selected: store.selectedRecord?.id == record.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { store.selectedID = record.id }
                                    .onTapGesture(count: 2) { store.copy(record, paste: true) }
                                    .contextMenu {
                                        Button("粘贴") { store.copy(record, paste: true) }
                                        Button("复制") { store.copy(record, paste: false) }
                                        Divider()
                                        Button(record.favorite ? "取消收藏" : "收藏") { store.favorite(record) }
                                        Button("删除", role: .destructive) { store.delete(record) }
                                    }
                                    .id(record.id)
                            }
                        }
                    }
                    .onChange(of: store.selectedID) { _, value in
                        if let value { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(value, anchor: .center) } }
                    }
                }
            }
            if let message = store.message {
                HStack(alignment: .top) {
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button { store.clearMessage() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("关闭提示")
                }
            }
            HStack {
                Text("\(store.filteredRecords.count) 条").foregroundStyle(.secondary)
                Spacer()
                Button("复制") { store.copySelected(paste: false) }
                    .disabled(store.selectedRecord == nil || store.busy)
                Button("粘贴") { store.copySelected(paste: true) }
                    .disabled(store.selectedRecord == nil || store.busy)
            }
            .font(.caption)
            .buttonStyle(.plain)
        }
        .padding(.bottom, 8)
        .onAppear {
            store.start()
            if store.keyboardSessionActive { focusSearch() }
        }
        .onChange(of: store.keyboardSessionActive) { _, value in
            if value { focusSearch() } else { searchFocused = false }
        }
        .onChange(of: store.search) { _, _ in store.selectedID = store.filteredRecords.first?.id }
        .onDisappear { searchFocused = false }
        .onKeyPress(.escape, phases: .down) { _ in
            guard !isComposing else { return .ignored }
            NotificationCenter.default.post(name: .clipboardDismissRequested, object: nil)
            return .handled
        }
    }
    private var isComposing: Bool { (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false }
    private func focusSearch() {
        Task { @MainActor in await Task.yield(); searchFocused = true }
    }
}

private struct ClipboardHistoryRow: View {
    let record: ClipboardHistoryRecord
    let selected: Bool
    @State private var thumbnail: NSImage?
    private var icon: String {
        switch record.kind { case .image: "photo"; case .file: "doc"; case .text: "text.alignleft" }
    }
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit()
                } else {
                    Image(systemName: icon).font(.title3).foregroundStyle(.secondary)
                }
            }
            .frame(width: 50, height: 42)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).lineLimit(2).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if let source = record.sourceName { Text(source).lineLimit(1) }
                    Text(record.copiedAt, style: .relative).lineLimit(1)
                    if record.itemCount > 1 { Text("\(record.itemCount) 项") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            if record.favorite { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(8)
        .background(selected ? Color.white.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .task(id: record.id) { thumbnail = await ClipboardStore.shared.thumbnail(for: record) }
        .onDisappear { thumbnail = nil }
    }
}
