import EventKit
import Foundation

/// Calendar via EventKit rather than AppleScript.
///
/// Calendar.app's AppleScript interface is famously slow — a week's query can
/// take tens of seconds. EventKit answers the same question in milliseconds and
/// asks for consent properly.
struct ListCalendarTool: Tool {
    let activityLabel = "Bekijkt je agenda"
    let name = "list_calendar"
    let description = """
    Geeft afspraken uit de agenda voor een aantal dagen vooruit. \
    Gebruik dit voor 'wat staat er vandaag op de planning' of 'ben ik vrij donderdag'.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "days":{"type":"integer","description":"Aantal dagen vooruit vanaf nu. Standaard 1 (vandaag), maximaal 30."}},
     "required":[]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let days = min(max(arguments.int("days", default: 1), 1), 30)
        let store = EKEventStore()

        guard try await store.requestFullAccessToEvents() else {
            throw ToolError.unavailable(
                "Geen agenda-toegang. Sta NotchAI toe in Systeeminstellingen → Privacy en beveiliging → Agenda.")
        }

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        guard !events.isEmpty else {
            return "Geen afspraken in de komende \(days) dag(en)."
        }

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEE d MMM HH:mm"

        let lines = events.prefix(40).map { event -> String in
            let when = event.isAllDay
                ? "\(formatter.string(from: event.startDate)) (hele dag)"
                : "\(formatter.string(from: event.startDate))–\(DateFormatter.localizedString(from: event.endDate, dateStyle: .none, timeStyle: .short))"
            let location = event.location.map { " @ \($0)" } ?? ""
            return "\(when) | \(event.title ?? "(zonder titel)")\(location)"
        }
        return "\(events.count) afspraken:\n" + lines.joined(separator: "\n")
    }
}


/// Creating events. EventKit writes directly, so unlike mail this needs no
/// human hand-off — but it changes your calendar, so it still asks first.
struct CreateCalendarEventTool: Tool {
    let activityLabel = "Maakt een afspraak"
    let name = "create_calendar_event"
    let description = """
    Maakt een afspraak in de standaardagenda. Geef de starttijd als ISO-8601 \
    ("2026-08-05T14:00") of als natuurlijke datum-tijd in de lokale tijdzone.
    """
    let risk = ToolRisk.mutating
    let parametersJSON = """
    {"type":"object","properties":{
      "title":{"type":"string","description":"Titel van de afspraak."},
      "start":{"type":"string","description":"Starttijd, bijvoorbeeld 2026-08-05T14:00."},
      "duration_minutes":{"type":"integer","description":"Duur in minuten, standaard 60."},
      "location":{"type":"string","description":"Locatie, optioneel."},
      "notes":{"type":"string","description":"Notities, optioneel."}},
     "required":["title","start"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let title = try arguments.requiredString("title")
        let startText = try arguments.requiredString("start")
        let minutes = arguments.int("duration_minutes", default: 60)

        guard let start = Self.parse(startText) else {
            throw ToolError.unavailable("Kon '\(startText)' niet als datum-tijd lezen. Gebruik 2026-08-05T14:00.")
        }

        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            throw ToolError.unavailable(
                "Geen agenda-toegang. Sta NotchAI toe in Systeeminstellingen → Privacy en beveiliging → Agenda.")
        }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw ToolError.unavailable("Geen standaardagenda gevonden om in te schrijven.")
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(minutes * 60))
        event.location = arguments.string("location")
        event.notes = arguments.string("notes")

        try store.save(event, span: .thisEvent)

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEEE d MMMM HH:mm"
        return "'\(title)' staat in \(calendar.title) op \(formatter.string(from: start)), \(minutes) minuten."
    }

    /// Accept both the strict ISO form the prompt asks for and the looser
    /// variants models actually emit.
    private static func parse(_ text: String) -> Date? {
        let iso = ISOStrategy()
        if let date = iso.parse(text) { return date }

        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                       "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm",
                       "dd/MM/yyyy HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private struct ISOStrategy {
        func parse(_ text: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = .current
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime,
                                       .withDashSeparatorInDate]
            return formatter.date(from: text)
        }
    }
}
