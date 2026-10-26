import AppKit
import IslandCore

@MainActor
final class VikunjaCalendarService: CalendarServiceProviding {
    private var client: (any TodoServiceProviding)?
    private var projectModels: [CalendarModel] = []
    init(client: (any TodoServiceProviding)? = nil) { self.client = client }
    private func service() throws -> any TodoServiceProviding {
        if let client { return client }
        let client = VikunjaClient(configuration: try IslandSettings.todo())
        self.client = client
        return client
    }
    func calendars() async throws -> [CalendarModel] {
        projectModels = try await service().projects().map {
            CalendarModel(id: "vikunja:project:\($0.id)", account: "Vikunja", title: $0.title,
                          color: .systemTeal, isSubscribed: false, isReminder: true)
        }
        return projectModels
    }
    func events(from start: Date, to end: Date, calendars: [String]) async throws -> [EventModel] {
        let configuration = try IslandSettings.todo()
        let isToday = Calendar.current.isDateInToday(start)
        let tasks = try await service().tasks()
        return tasks.compactMap { task in
            let projectID = "vikunja:project:\(task.projectID)"
            guard calendars.contains(projectID), let project = projectModels.first(where: { $0.id == projectID }) else { return nil }
            if let due = task.due {
                guard (due >= start && due < end) || (isToday && due < start && !task.done) else { return nil }
            } else if !isToday { return nil }
            return EventModel(id: "vikunja:task:\(task.id)", start: task.due ?? start,
                              end: task.due ?? end, title: task.title, location: nil, notes: task.description,
                              url: configuration.baseURL.appendingPathComponent("tasks/\(task.id)"),
                              isAllDay: task.due == nil, type: .reminder(completed: task.done), calendar: project,
                              participants: [], timeZone: nil, hasRecurrenceRules: false,
                              priority: (task.priority ?? 0) >= 3 ? .high : nil, isUnscheduled: task.due == nil)
        }.sorted { $0.start < $1.start }
    }
    func setReminderCompleted(reminderID: String, completed: Bool) async throws {
        guard reminderID.hasPrefix("vikunja:task:"), let id = Int(reminderID.dropFirst("vikunja:task:".count)) else {
            throw IslandError.invalidResponse
        }
        try await service().setCompleted(taskID: id, completed: completed)
    }
}
