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
