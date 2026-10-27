import AppKit
import IslandCore
import SwiftUI

struct ClipboardDrawer: View {
    @ObservedObject private var store = ClipboardStore.shared
    @ObservedObject private var presentation = ClipboardPresentation.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var contentRowFrames: [String: CGRect] = [:]
    @State private var visibleContentRect: CGRect = .zero
    @State private var focusTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索剪贴板", text: $store.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .background(InteractionInputProbe(region: "clipboard.search"))
                    .onKeyPress(.downArrow, phases: [.down, .repeat]) { handle(.down, press: $0) }
                    .onKeyPress(.upArrow, phases: [.down, .repeat]) { handle(.up, press: $0) }
                    .onKeyPress(.return, phases: .down) { handle(.enter, press: $0) }
                    .onKeyPress(.escape, phases: .down) { handle(.escape, press: $0) }
                if !store.search.isEmpty {
                    Button { store.search = ""; focusSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("清空搜索")
                }
            }
            .padding(10)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

            if !store.enabled {
                HStack {
                    Button("启用剪贴板历史") { store.requestPermissions() }.disabled(store.requestingPermissions)
                    Spacer()
                }.font(.caption)
            } else if store.readDenied {
                HStack {
                    Button("允许剪贴板访问") { store.requestPermissions() }.disabled(store.requestingPermissions)
                    Spacer()
                }.font(.caption)
            } else if store.needsReadAccess {
                HStack {
                    Button("允许读取剪贴板") { store.requestPermissions() }.disabled(store.requestingPermissions)
                    Spacer()
                }.font(.caption)
            }
            if store.enabled && store.needsPasteAccess && !store.needsReadAccess && !store.readDenied {
                HStack {
                    Button("允许自动粘贴") { store.requestPermissions() }.disabled(store.requestingPermissions)
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
                                ClipboardHistoryRow(record: record, selected: store.selectedID == record.id,
                                    activating: store.busy && store.selectedID == record.id)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Button("粘贴") { store.copy(record, paste: true) }
                                        Button("复制") { store.copy(record, paste: false) }
                                        Divider()
                                        Button(record.favorite ? "取消收藏" : "收藏") { store.favorite(record) }
                                        Button("删除", role: .destructive) { store.delete(record) }
                                    }
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(key: ClipboardRowFrames.self,
                                                value: [record.id: geometry.frame(in: .named("clipboardViewport"))])
                                                .preference(key: ClipboardContentRowFrames.self,
                                                    value: [record.id: geometry.frame(in: .named("clipboardContent"))])
                                        }
                                    }
                                    .id(record.id)
                            }
                        }
                        .coordinateSpace(name: "clipboardContent")
                    }
                    .coordinateSpace(name: "clipboardViewport")
                    .background {
                        GeometryReader { _ in
                            ClipboardPointerObserver(rowFrames: rowFrames,
                                keyboardRevision: store.keyboardSelectionRevision,
                                select: { id in store.select(id) }, activate: { id in
                                    guard let record = store.filteredRecords.first(where: { $0.id == id }) else { return }
                                    store.copy(record, paste: true)
                                })

                        }
                    }
                    .onPreferenceChange(ClipboardRowFrames.self) { rowFrames = $0 }
                    .onPreferenceChange(ClipboardContentRowFrames.self) { contentRowFrames = $0 }
                    .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rectangle in
                        visibleContentRect = rectangle
                    }
                    .onChange(of: store.keyboardSelectionRevision) { _, _ in
                        guard let id = store.selectedID,
                              let edge = ClipboardSelectionPolicy.scrollEdge(row: contentRowFrames[id],
                                viewport: visibleContentRect, direction: store.keyboardSelectionDirection) else { return }
                        // Arrow keys reveal only the clipped edge; mouse selection never scrolls the list.
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: edge == .top ? .top : .bottom)
                        }
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
                Text("↑↓ 选择  ·  ↩ 粘贴  ·  ⌘↩ 复制")
                    .foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                Button("复制") { store.copySelected(paste: false) }
                    .disabled(store.selectedRecord == nil || store.busy || store.pasting)
                Button("粘贴") { store.copySelected(paste: true) }
                    .disabled(store.selectedRecord == nil || store.busy || store.pasting)
            }
            .font(.caption)
            .buttonStyle(.plain)
        }
        .padding(.bottom, 8)
        .focusable()
        .focusEffectDisabled()
        // Keep one keyboard handler on the drawer: buttons and row clicks must not disable navigation.
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { handle(.down, press: $0) }
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { handle(.up, press: $0) }
        .onKeyPress(.return, phases: .down) { handle(.enter, press: $0) }
        .onKeyPress(.escape, phases: .down) { handle(.escape, press: $0) }
        .onAppear {
            store.start()
        }
        .onChange(of: searchFocused) { _, value in InteractionDiagnostics.record("clipboard.input", "focus-state", ["allowed": String(value), "session": store.sessionID.uuidString]) }
        .onChange(of: store.sessionID) { _, _ in searchFocused = false }
        .onChange(of: store.keyboardSessionActive) { _, value in
            if !value { focusTask?.cancel(); searchFocused = false }
        }
        .background(HermesInputFocusObserver(enabled: presentation.sessionPresented && presentation.keyboardTargetReady,
            activation: store.sessionID,
            isCurrent: { BoringViewCoordinator.shared.currentView == .clipboard },
            setFocused: { value in if searchFocused != value { searchFocused = value } }))
        .onDisappear { focusTask?.cancel(); focusTask = nil; searchFocused = false; rowFrames = [:]; contentRowFrames = [:] }
    }

    private var isComposing: Bool { (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false }
    private func handle(_ key: ClipboardSelectionPolicy.Key, press: KeyPress) -> KeyPress.Result {
        InteractionDiagnostics.record("clipboard.input", "key-handler", ["key": String(describing: key), "command": String(press.modifiers.contains(.command)), "composing": String(isComposing), "repeating": String(press.phase == .repeat), "selected": String(store.selectedRecord != nil)])
        switch ClipboardSelectionPolicy.action(for: key, repeating: press.phase == .repeat,
                                                command: press.modifiers.contains(.command), composing: isComposing) {
        case .move(let direction): store.moveSelection(direction)
        case .activate(let paste): store.copySelected(paste: paste)
        case .dismiss: store.dismiss()
        case .ignored: return .ignored
        }
        return .handled
    }
    private func focusSearch() {
        focusTask?.cancel()
        let session = store.sessionID
        focusTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, store.sessionID == session else { return }
            searchFocused = true
        }
    }
}

private struct ClipboardRowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ClipboardContentRowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Observe local events without becoming a hit target or stealing the search field's first responder.
/// A single observer covers the visible list; native context menus and scrolling keep their events.
private struct ClipboardPointerObserver: NSViewRepresentable {
    let rowFrames: [String: CGRect]
    let keyboardRevision: UInt
    let select: (String) -> Void
    let activate: (String) -> Void

    final class ObserverView: NSView {
        var rowFrames: [String: CGRect] = [:]
        var select: ((String) -> Void)?
        var activate: ((String) -> Void)?
        private var keyboardRevision: UInt?
        private var pointerGate = ClipboardPointerSelectionGate()
        private var pointerActivation = ClipboardPointerActivation()
        private var monitor: Any?
        private var pointerTracking: NSTrackingArea?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func receive(rowFrames: [String: CGRect], keyboardRevision: UInt,
                     select: @escaping (String) -> Void, activate: @escaping (String) -> Void) {
            self.rowFrames = rowFrames
            self.select = select
            self.activate = activate
            if self.keyboardRevision != keyboardRevision {
                self.keyboardRevision = keyboardRevision
                pointerGate.keyboardNavigated(pointerAt: NSEvent.mouseLocation)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                                                  .rightMouseDown, .scrollWheel, .mouseMoved]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return consumed ? nil : event
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let pointerTracking { removeTrackingArea(pointerTracking) }
            let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                          owner: self, userInfo: nil)
            addTrackingArea(tracking)
            pointerTracking = tracking
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return false }
            let point = convert(event.locationInWindow, from: nil)
            if event.type == .scrollWheel || event.type == .rightMouseDown {
                pointerActivation.cancelActivation()
                return false
            }
            if event.type == .leftMouseDragged {
                pointerActivation.mouseDragged(to: point)
                return false
            }
            let id = hitRowID(event, in: window, at: point)
            if InteractionDiagnostics.enabled, event.type == .leftMouseDown || event.type == .leftMouseUp {
                var fields = InteractionDiagnostics.windowFields(window)
                fields.merge(["event": String(event.type.rawValue), "eventNumber": String(event.eventNumber),
                    "rowHit": String(id != nil), "count": String(rowFrames.count), "clickCount": String(event.clickCount), "width": String(describing: bounds.width), "height": String(describing: bounds.height), "x": String(describing: point.x), "y": String(describing: point.y)]) { _, new in new }
                InteractionDiagnostics.record("clipboard.input", "row-pointer", fields)
            }
            if event.type == .leftMouseDown {
                let result = pointerActivation.mouseDown(rowID: id, at: point, clickCount: event.clickCount)
                if result.consumesEvent, let id { select?(id) }
                return result.consumesEvent
            }
            if event.type == .leftMouseUp {
                let result = pointerActivation.mouseUp(rowID: id, at: point)
                InteractionDiagnostics.record("clipboard.input", "row-release", ["consumed": String(result.consumesEvent), "selected": String(result.activatedID != nil)])
                if let activated = result.activatedID { activate?(activated) }
                // Activation closes the panel. Do not let AppKit handle this click afterwards
                // and make the closing panel key again instead of the paste destination.
                return result.consumesEvent
            }
            if event.type == .mouseMoved, let id,
               pointerGate.acceptsMovement(at: NSEvent.mouseLocation,
                   delta: CGSize(width: event.deltaX, height: event.deltaY)) {
                select?(id)
            }
            return false
        }

        private func hitRowID(_ event: NSEvent, in window: NSWindow, at point: CGPoint) -> String? {
            // Overlay scrollers cover row geometry, but clicking their thumb/track is scrolling,
            // never row selection or double-click paste. hitTest expects its superview's coordinates.
            if let contentView = window.contentView {
                let hitPoint = contentView.superview?.convert(event.locationInWindow, from: nil)
                    ?? event.locationInWindow
                var hit = contentView.hitTest(hitPoint)
                while let view = hit {
                    if view is NSScroller { return nil }
                    hit = view.superview
                }
            }
            return ClipboardSelectionPolicy.hitID(at: point, viewport: bounds.intersection(visibleRect), rows: rowFrames)
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            pointerActivation.cancel()
        }
    }

    func makeNSView(context: Context) -> ObserverView { ObserverView(frame: .zero) }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.receive(rowFrames: rowFrames, keyboardRevision: keyboardRevision, select: select, activate: activate)
    }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stopMonitoring() }
}

private struct ClipboardHistoryRow: View {
    let record: ClipboardHistoryRecord
    let selected: Bool
    let activating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    if let source = record.sourceName, !source.isEmpty { Text(source).lineLimit(1) }
                    if record.itemCount > 1 { Text("\(record.itemCount) 项") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Group {
                if activating {
                    ProgressView().controlSize(.small)
                } else if selected {
                    Image(systemName: "return").font(.caption).foregroundStyle(.secondary)
                } else { Color.clear }
            }.frame(width: 20, height: 20)
            if record.favorite { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(8)
        .background(selected ? Color.white.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(selected ? 0.12 : 0), lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .task(id: record.id) { thumbnail = await ClipboardStore.shared.thumbnail(for: record) }
        .onDisappear { thumbnail = nil }
    }
}
