import SwiftUI
import Defaults

struct TodoTimelineView: View {
    @ObservedObject private var manager = CalendarManager.shared
    @State private var selectedDate = Date()
    @State private var refreshToken = UUID()
    @Default(.hideCompletedReminders) private var hideCompleted
    @Environment(\.openURL) private var openURL

    private var visibleEvents: [EventModel] {
        manager.events.filter {
            if case .reminder(let completed) = $0.type { return !hideCompleted || !completed }
            return true
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                DatePicker("Tasks", selection: $selectedDate, displayedComponents: .date).labelsHidden()
                Spacer()
                if manager.isLoading { ProgressView().controlSize(.mini) }
                Button("Refresh", systemImage: "arrow.clockwise") { refreshToken = UUID() }
                    .labelStyle(.iconOnly).buttonStyle(.plain)
            }
            if let error = manager.errorMessage {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(error)
                    Button("Retry") { refreshToken = UUID() }.font(.caption)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    taskGroup("截止日程", events: visibleEvents.filter { !$0.isUnscheduled })
                    taskGroup("未排期", events: visibleEvents.filter(\.isUnscheduled))
                    if visibleEvents.isEmpty && manager.errorMessage == nil && !manager.isLoading {
                        Text("没有待办").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 120)
        .onChange(of: selectedDate) { refreshToken = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: .islandConfigurationChanged)) { _ in refreshToken = UUID() }
        .task(id: refreshToken) {
            await manager.updateCurrentDate(selectedDate)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard !Task.isCancelled else { return }
                await manager.updateCurrentDate(selectedDate)
            }
        }
    }
    @ViewBuilder private func taskGroup(_ title: String, events: [EventModel]) -> some View {
        if !events.isEmpty {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            ForEach(events) { event in
                HStack(spacing: 6) {
                    let completed = { if case .reminder(let value) = event.type { return value }; return false }()
                    Button {
                        Task { await manager.setReminderCompleted(reminderID: event.id, completed: !completed) }
                    } label: {
                        Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                    }.buttonStyle(.plain).disabled(manager.pendingTaskIDs.contains(event.id))
                    Button { if let url = event.url { openURL(url) } } label: {
                        Text(event.title).lineLimit(1).strikethrough(completed)
                    }.buttonStyle(.plain).help(event.title)
                    Spacer(minLength: 0)
                    if !event.isUnscheduled {
                        Text(event.start, format: .dateTime.month().day().hour().minute())
                            .font(.caption2).foregroundStyle(event.start < Date() && !completed ? Color.orange : Color.secondary)
                    }
                }.font(.caption)
            }
        }
    }
}
