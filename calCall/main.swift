//
//  main.swift
//  calCall
//
//  Created by Benjamin Rannow on 03.03.26.
//

import Foundation
import MCP

let calendarService = CalendarService()

// Request calendar access (non-fatal — errors surface in tool calls)
let hasAccess = await calendarService.requestAccess()
if !hasAccess {
    // Log to stderr so it doesn't interfere with stdio MCP transport
    FileHandle.standardError.write(Data("WARNING: Calendar access not granted. Grant permission in System Settings > Privacy & Security > Calendars.\n".utf8))
}

let server = Server(
    name: "calCall",
    version: "1.0.0",
    instructions: "Read-only calendar access. Use list_calendars to discover calendars, then get_events to query events by date range. For time booking in CET, pass timezone: \"Europe/Berlin\".",
    capabilities: Server.Capabilities(
        tools: .init()
    )
)

// MARK: - Tool Definitions

let listCalendarsTool = Tool(
    name: "list_calendars",
    description: "List all available calendars on this Mac. Returns calendar ID, name, type, and account. Use the calendar ID to filter get_events.",
    inputSchema: .object([
        "type": "object",
        "properties": .object([:])
    ]),
    annotations: .init(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )
)

let getEventsTool = Tool(
    name: "get_events",
    description: "Get calendar events within a date range. Returns id, title, start, end, duration_minutes, and calendar_name. All-day events and cancelled events are excluded. Use the event id with get_event_detail to fetch description and other details.",
    inputSchema: .object([
        "type": "object",
        "properties": .object([
            "start_date": .object([
                "type": "string",
                "description": "Range start as ISO 8601 datetime (e.g. 2026-03-01T00:00:00)"
            ]),
            "end_date": .object([
                "type": "string",
                "description": "Range end as ISO 8601 datetime (e.g. 2026-03-04T00:00:00)"
            ]),
            "calendar_ids": .object([
                "type": "array",
                "items": .object(["type": "string"]),
                "description": "Optional array of calendar IDs to filter by. Get IDs from list_calendars."
            ]),
            "timezone": .object([
                "type": "string",
                "description": "IANA timezone identifier for returned times (e.g. Europe/Berlin, Asia/Bangkok). Defaults to system timezone."
            ])
        ]),
        "required": .array([.string("start_date"), .string("end_date")])
    ]),
    annotations: .init(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )
)

let getEventDetailTool = Tool(
    name: "get_event_detail",
    description: "Get extra details (description, location, URL) of a calendar event by its ID. Use this when the event title alone is not enough to determine the booking category. Does NOT return dates — use the dates from get_events.",
    inputSchema: .object([
        "type": "object",
        "properties": .object([
            "event_id": .object([
                "type": "string",
                "description": "The event ID from get_events results."
            ])
        ]),
        "required": .array([.string("event_id")])
    ]),
    annotations: .init(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
    )
)

// MARK: - Handler Registration

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: [listCalendarsTool, getEventsTool, getEventDetailTool])
}

await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case "list_calendars":
        do {
            let calendars = try calendarService.listCalendars()
            let lines = calendars.map { cal in
                "[\(cal.id)] \(cal.name) (\(cal.type), \(cal.account))"
            }
            let text = calendars.isEmpty ? "No calendars found." : lines.joined(separator: "\n")
            return .init(content: [.text(text)])
        } catch {
            return .init(content: [.text("\(error)")], isError: true)
        }

    case "get_events":
        let startStr = params.arguments?["start_date"]?.stringValue
        let endStr = params.arguments?["end_date"]?.stringValue

        guard let startStr, let endStr else {
            return .init(content: [.text("Missing required parameters: start_date and end_date")], isError: true)
        }

        let isoParser = ISO8601DateFormatter()
        isoParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Try with fractional seconds first, then without
        var startDate = isoParser.date(from: startStr)
        var endDate = isoParser.date(from: endStr)

        if startDate == nil || endDate == nil {
            isoParser.formatOptions = [.withInternetDateTime]
            if startDate == nil { startDate = isoParser.date(from: startStr) }
            if endDate == nil { endDate = isoParser.date(from: endStr) }
        }

        // Also try without timezone (bare datetime)
        if startDate == nil || endDate == nil {
            let bareFormatter = DateFormatter()
            bareFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            bareFormatter.timeZone = TimeZone.current
            if startDate == nil { startDate = bareFormatter.date(from: startStr) }
            if endDate == nil { endDate = bareFormatter.date(from: endStr) }
        }

        guard let start = startDate else {
            return .init(content: [.text("Invalid start_date format: \(startStr). Use ISO 8601 (e.g. 2026-03-01T00:00:00)")], isError: true)
        }
        guard let end = endDate else {
            return .init(content: [.text("Invalid end_date format: \(endStr). Use ISO 8601 (e.g. 2026-03-04T00:00:00)")], isError: true)
        }

        // Parse timezone
        var timezone = TimeZone.current
        if let tzStr = params.arguments?["timezone"]?.stringValue {
            guard let tz = TimeZone(identifier: tzStr) else {
                return .init(content: [.text("Invalid timezone: \(tzStr). Use IANA identifiers like Europe/Berlin or Asia/Bangkok.")], isError: true)
            }
            timezone = tz
        }

        // Parse optional calendar IDs
        let calendarIds = params.arguments?["calendar_ids"]?.arrayValue?.compactMap { $0.stringValue }

        let events: [EventInfo]
        do {
            events = try calendarService.getEvents(
                startDate: start,
                endDate: end,
                calendarIds: calendarIds,
                timezone: timezone
            )
        } catch {
            return .init(content: [.text("\(error)")], isError: true)
        }

        if events.isEmpty {
            return .init(content: [.text("No events found in the specified range.")])
        }

        let lines = events.map { event in
            "\(event.id) | \(event.title) | \(event.start) - \(event.end) | \(event.durationMinutes)min | \(event.calendarName)"
        }
        return .init(content: [.text(lines.joined(separator: "\n"))])

    case "get_event_detail":
        guard let eventId = params.arguments?["event_id"]?.stringValue else {
            return .init(content: [.text("Missing required parameter: event_id")], isError: true)
        }

        do {
            guard let detail = try calendarService.getEventDetail(eventId: eventId) else {
                return .init(content: [.text("Event not found: \(eventId)")], isError: true)
            }

            var lines = ["Title: \(detail.title)"]
            if let desc = detail.description, !desc.isEmpty {
                lines.append("Description: \(desc)")
            }
            if let loc = detail.location, !loc.isEmpty {
                lines.append("Location: \(loc)")
            }
            if let url = detail.url, !url.isEmpty {
                lines.append("URL: \(url)")
            }
            return .init(content: [.text(lines.joined(separator: "\n"))])
        } catch {
            return .init(content: [.text("\(error)")], isError: true)
        }

    default:
        return .init(content: [.text("Unknown tool: \(params.name)")], isError: true)
    }
}

// MARK: - Start Server

let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
