import EventKit
import Foundation

struct CalendarInfo: Sendable {
    let id: String
    let name: String
    let type: String
    let account: String
}

struct EventInfo: Sendable {
    let id: String
    let title: String
    let start: String
    let end: String
    let durationMinutes: Int
    let calendarName: String
}

struct EventDetail: Sendable {
    let title: String
    let description: String?
    let location: String?
    let url: String?
}

final class CalendarService: @unchecked Sendable {
    private let store = EKEventStore()
    private var accessGranted = false

    func ensureAccess() throws {
        if accessGranted { return }

        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess:
            accessGranted = true
        case .notDetermined:
            throw CalendarError.accessNotDetermined
        case .denied, .restricted, .writeOnly:
            throw CalendarError.accessDenied
        @unknown default:
            throw CalendarError.accessDenied
        }
    }

    func requestAccess() async -> Bool {
        do {
            if #available(macOS 14.0, *) {
                accessGranted = try await store.requestFullAccessToEvents()
            } else {
                accessGranted = try await store.requestAccess(to: .event)
            }
        } catch {
            accessGranted = false
        }
        return accessGranted
    }

    func listCalendars() throws -> [CalendarInfo] {
        try ensureAccess()
        return store.calendars(for: .event).map { cal in
            CalendarInfo(
                id: cal.calendarIdentifier,
                name: cal.title,
                type: calendarTypeName(cal.type),
                account: cal.source?.title ?? "Unknown"
            )
        }
    }

    func getEvents(
        startDate: Date,
        endDate: Date,
        calendarIds: [String]?,
        timezone: TimeZone
    ) throws -> [EventInfo] {
        try ensureAccess()
        var calendars: [EKCalendar]? = nil
        if let ids = calendarIds {
            calendars = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
        }

        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        let events = store.events(matching: predicate)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timezone

        return events
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                let durationSeconds = event.endDate.timeIntervalSince(event.startDate)
                let durationMinutes = Int(durationSeconds / 60)

                return EventInfo(
                    id: event.eventIdentifier,
                    title: event.title ?? "Untitled",
                    start: formatter.string(from: event.startDate),
                    end: formatter.string(from: event.endDate),
                    durationMinutes: durationMinutes,
                    calendarName: event.calendar?.title ?? "Unknown"
                )
            }
    }

    func getEventDetail(eventId: String) throws -> EventDetail? {
        try ensureAccess()
        guard let event = store.event(withIdentifier: eventId) else {
            return nil
        }

        return EventDetail(
            title: event.title ?? "Untitled",
            description: event.notes,
            location: event.location,
            url: event.url?.absoluteString
        )
    }

    private func calendarTypeName(_ type: EKCalendarType) -> String {
        switch type {
        case .local: return "local"
        case .calDAV: return "calDAV"
        case .exchange: return "exchange"
        case .subscription: return "subscription"
        case .birthday: return "birthday"
        @unknown default: return "unknown"
        }
    }
}

enum CalendarError: Error, CustomStringConvertible {
    case accessDenied
    case accessNotDetermined
    case invalidDate(String)
    case invalidTimezone(String)

    var description: String {
        switch self {
        case .accessDenied:
            return "Calendar access denied. Grant permission in System Settings > Privacy & Security > Calendars."
        case .accessNotDetermined:
            return "Calendar access not yet granted. Run the cal-mcp binary directly once from Terminal to trigger the permission prompt, then grant access in System Settings > Privacy & Security > Calendars."
        case .invalidDate(let value):
            return "Invalid ISO 8601 date: \(value)"
        case .invalidTimezone(let value):
            return "Invalid timezone identifier: \(value)"
        }
    }
}
