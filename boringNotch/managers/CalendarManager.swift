import Combine
import Defaults
import SwiftUI

@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()
    @Published var currentWeekStartDate = Calendar.current.startOfDay(for: Date())
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var pendingTaskIDs: Set<String> = []
    private var calendarService: any CalendarServiceProviding
    private var refreshID = UUID()
    private var configurationObserver: AnyCancellable?

    init(service: (any CalendarServiceProviding)? = nil) {
        calendarService = service ?? VikunjaCalendarService()
        configurationObserver = NotificationCenter.default.publisher(for: .islandConfigurationChanged).sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.calendarService = VikunjaCalendarService()
                self.refreshID = UUID()
                self.isLoading = false
                self.events = []; self.allCalendars = []; self.reminderLists = []
                self.errorMessage = nil
            }
        }
    }
    func reloadCalendarAndReminderLists() async { await refresh() }
    func refresh() async {
        guard !isLoading else { return }
        let id = UUID(); refreshID = id; isLoading = true
        let service = calendarService
        let start = currentWeekStartDate
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        do {
            let calendars = try await service.calendars()
            try Task.checkCancellation()
            guard id == refreshID else { return }
            allCalendars = calendars; reminderLists = calendars; eventCalendars = []
            updateSelectedCalendars()
            let result = try await service.events(from: start, to: end, calendars: Array(selectedCalendarIDs))
            try Task.checkCancellation()
            guard id == refreshID else { return }
            events = result; errorMessage = nil
        } catch is CancellationError {
        } catch {
            if id == refreshID { errorMessage = error.localizedDescription }
        }
        if id == refreshID { isLoading = false }
    }
    func updateSelectedCalendars() {
        switch Defaults[.calendarSelectionState] {
        case .all: selectedCalendarIDs = Set(allCalendars.map(\.id))
        case .selected(let ids): selectedCalendarIDs = ids.intersection(Set(allCalendars.map(\.id)))
        }
    }
    func getCalendarSelected(_ calendar: CalendarModel) -> Bool { selectedCalendarIDs.contains(calendar.id) }
    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var ids = selectedCalendarIDs
        if isSelected { ids.insert(calendar.id) } else { ids.remove(calendar.id) }
        Defaults[.calendarSelectionState] = .selected(ids)
        updateSelectedCalendars()
        await refresh()
    }
    static func startOfDay(_ date: Date) -> Date { Calendar.current.startOfDay(for: date) }
    func updateCurrentDate(_ date: Date) async {
        let day = Calendar.current.startOfDay(for: date)
        if currentWeekStartDate != day {
            refreshID = UUID(); isLoading = false
            currentWeekStartDate = day
            events = []
        }
        await refresh()
    }
    func setReminderCompleted(reminderID: String, completed: Bool) async {
        guard pendingTaskIDs.insert(reminderID).inserted else { return }
        defer { pendingTaskIDs.remove(reminderID) }
        let service = calendarService
        do {
            try await service.setReminderCompleted(reminderID: reminderID, completed: completed)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }
}
