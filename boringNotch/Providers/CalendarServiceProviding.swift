import Foundation

/// UI-facing adapter; no Apple calendar authorization or EventKit types cross this boundary.
@MainActor
protocol CalendarServiceProviding {
    func calendars() async throws -> [CalendarModel]
    func events(from start: Date, to end: Date, calendars: [String]) async throws -> [EventModel]
    func setReminderCompleted(reminderID: String, completed: Bool) async throws
}
