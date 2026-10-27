import AppKit
import IslandCore
import SwiftUI

struct HermesContextPicker: View {
    @ObservedObject private var store = HermesStore.shared
    @ObservedObject private var shelf = ShelfStateViewModel.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @State private var search = ""
    let close: () -> Void

    private var files: [ShelfItem] {
        shelf.items.filter {
            guard case .file = $0.kind else { return false }
            return search.isEmpty || $0.displayName.localizedStandardContains(search)
        }
    }
    private var records: [ClipboardHistoryRecord] {
        clipboard.records.filter {
            $0.kind != .file && (search.isEmpty || $0.title.localizedStandardContains(search) || $0.searchableText.localizedStandardContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("搜索附件…", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text("暂存区").font(.caption).foregroundStyle(.secondary)
                    if files.isEmpty { Text("暂无文件").font(.caption).foregroundStyle(.secondary) }
                    ForEach(files) { item in
                        Button { store.toggleShelfItem(item.id) } label: {
                            HStack {
                                Image(systemName: "doc")
                                Text(item.displayName).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if store.selectedShelfIDs.contains(item.id) { Image(systemName: "checkmark") }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.vertical, 4)
                    }
                    Divider()
                    Text("剪贴板").font(.caption).foregroundStyle(.secondary)
                    if records.isEmpty { Text("暂无文本或图片").font(.caption).foregroundStyle(.secondary) }
                    ForEach(records) { record in
                        Button { store.stageClipboard(record.id); close() } label: {
                            HermesClipboardContextRow(record: record)
                        }.buttonStyle(.plain).padding(.vertical, 4)
                    }
                }
            }
        }
        .font(.callout).padding(14).frame(width: 360, height: 340)
        .disabled(store.isGenerating || store.isPreparingDrop)
    }
}

private struct HermesClipboardContextRow: View {
    let record: ClipboardHistoryRecord
    @State private var thumbnail: NSImage?
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                else { Image(systemName: record.kind == .image ? "photo" : "text.alignleft") }
            }.frame(width: 42, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.kind == .image ? "图片" : record.title).lineLimit(2)
                if let source = record.sourceName { Text(source).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Image(systemName: "plus")
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .task(id: record.id) {
            if record.kind == .image { thumbnail = await ClipboardStore.shared.thumbnail(for: record) }
        }
    }
}
