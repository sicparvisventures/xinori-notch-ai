import EventKit
import Foundation

/// Reminders through EventKit.
///
/// The old `~/Library/Group Containers/group.com.apple.reminders` SQLite path is
/// gone on macOS 26, and EventKit is the supported route anyway — it shares the
/// permission grant with the calendar tools, so this costs the user nothing extra.
struct ListRemindersTool: Tool {
    let activityLabel = "Bekijkt je taken"
    let name = "list_reminders"
    let description = """
    Geeft openstaande herinneringen met hun vervaldatum. \
    Gebruik dit voor 'wat moet ik nog doen' of 'staat er nog iets open'.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "include_completed":{"type":"boolean","description":"Neem afgevinkte taken mee. Standaard false."},
      "limit":{"type":"integer","description":"Maximaal aantal, standaard 25."}},
     "required":[]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let includeCompleted = arguments["include_completed"] as? Bool ?? false
        let limit = min(arguments.int("limit", default: 25), 100)

        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw ToolError.unavailable(
                "Geen toegang tot herinneringen. Sta NotchAI toe in Systeeminstellingen → Privacy en beveiliging → Herinneringen.")
        }

        let predicate = includeCompleted
            ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)

        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }

        guard !reminders.isEmpty else { return "Geen openstaande taken." }

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "d MMM"

        let sorted = reminders.sorted { a, b in
            (a.dueDateComponents?.date ?? .distantFuture) < (b.dueDateComponents?.date ?? .distantFuture)
        }
        let lines = sorted.prefix(limit).map { reminder -> String in
            let due = reminder.dueDateComponents?.date.map { " · \(formatter.string(from: $0))" } ?? ""
            let done = reminder.isCompleted ? " [afgevinkt]" : ""
            return "\(reminder.title ?? "(zonder titel)")\(due)\(done)"
        }
        return "\(reminders.count) taken:\n" + lines.joined(separator: "\n")
    }
}

struct CreateReminderTool: Tool {
    let activityLabel = "Maakt een taak"
    let name = "create_reminder"
    let description = """
    Zet een taak in Herinneringen, optioneel met een vervaldatum. \
    Gebruik dit als de gebruiker iets niet wil vergeten.
    """
    let risk = ToolRisk.mutating
    let parametersJSON = """
    {"type":"object","properties":{
      "title":{"type":"string","description":"Wat er moet gebeuren."},
      "due":{"type":"string","description":"Vervaldatum als 2026-08-06T09:00, optioneel."},
      "notes":{"type":"string","description":"Extra toelichting, optioneel."}},
     "required":["title"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let title = try arguments.requiredString("title")

        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw ToolError.unavailable("Geen toegang tot herinneringen.")
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw ToolError.unavailable("Geen standaardlijst gevonden om in te schrijven.")
        }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = arguments.string("notes")

        var when = ""
        if let text = arguments.string("due"), let date = Self.parse(text) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date)
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.dateFormat = "EEEE d MMMM HH:mm"
            when = " voor \(formatter.string(from: date))"
        }

        try store.save(reminder, commit: true)
        return "Taak '\(title)'\(when) toegevoegd aan \(calendar.title)."
    }

    /// Same tolerant parsing as the calendar tool: models emit several shapes.
    private static func parse(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }

        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                       "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
