import Foundation

/// iMessage and SMS, read from Messages' own database.
///
/// `chat.db` holds 231k rows on the development machine, so this is
/// search-first: there is no useful "list all" here. Opened `immutable=1` so it
/// is safe to read while Messages is running.
struct SearchMessagesTool: Tool {
    let activityLabel = "Zoekt in je berichten"
    let name = "search_messages"
    let description = """
    Zoekt in je iMessage- en sms-berichten op tekst of op contact. \
    Gebruik dit voor 'wat zei X over Y' of 'heb ik iets gehoord van Z'.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "query":{"type":"string","description":"Woorden die in het bericht voorkomen."},
      "from":{"type":"string","description":"Naam of nummer van de afzender."},
      "limit":{"type":"integer","description":"Maximaal aantal berichten, standaard 12."}},
     "required":[]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let query = arguments.string("query") ?? ""
        let from = arguments.string("from") ?? ""
        let limit = min(arguments.int("limit", default: 12), 40)

        guard !query.isEmpty || !from.isEmpty else {
            throw ToolError.missingArgument("query of from")
        }

        let db = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Messages/chat.db")
        guard FileManager.default.fileExists(atPath: db.path) else {
            throw ToolError.unavailable("""
            Geen toegang tot je berichten. Zet NotchAI aan bij Systeeminstellingen → \
            Privacy en beveiliging → Volledige schijftoegang, en start de app opnieuw.
            """)
        }

        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "'", with: "''")
        }

        var conditions = ["m.text IS NOT NULL", "m.text != ''"]
        if !query.isEmpty { conditions.append("m.text LIKE '%\(escaped(query))%'") }
        if !from.isEmpty { conditions.append("h.id LIKE '%\(escaped(from))%'") }

        // Apple's epoch is 2001-01-01 and the column is nanoseconds since then.
        let sql = """
        SELECT
          COALESCE(h.id, 'onbekend'),
          CASE m.is_from_me WHEN 1 THEN 'jij' ELSE 'zij' END,
          datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime'),
          substr(replace(m.text, char(10), ' '), 1, 200)
        FROM message m
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY m.date DESC
        LIMIT \(limit);
        """

        let result = try await Shell.capture(
            "/usr/bin/sqlite3", ["-separator", " | ", "file:\(db.path)?immutable=1", sql],
            timeout: 30)

        guard result.status == 0 else {
            if FullDiskAccess.looksDenied(result.combined) { throw FullDiskAccess.error("je berichten") }
            throw ToolError.unavailable("Kon de berichten niet lezen: \(result.combined.prefix(160))")
        }

        let lines = result.stdout.split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return "Geen berichten gevonden." }
        return "\(lines.count) berichten:\n" + lines.joined(separator: "\n")
    }
}
