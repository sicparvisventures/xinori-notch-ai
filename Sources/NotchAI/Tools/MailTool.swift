import AppKit
import Foundation

/// Reads mail from Mail.app's own SQLite index rather than through AppleScript.
///
/// The AppleScript route does not work: on this machine Mail does not service
/// Apple Events at all — even `count of messages of inbox` returns -1712
/// (timeout) after 40 seconds. And `messages whose read status is false` forces
/// a full mailbox walk over Apple Events even when it does respond, which is
/// hopeless for an inbox with tens of thousands of messages.
///
/// The envelope index answers the same question in milliseconds. It is opened
/// `immutable=1` — strictly read-only, and safe to touch while Mail is running.
struct ListMailTool: Tool {
    let activityLabel = "Leest je mail"
    let name = "list_mail"
    let description = """
    Leest berichten uit Mail: afzender, onderwerp en datum. Kan filteren op \
    ongelezen en zoeken op afzender of onderwerp. Gebruik dit voor 'check mijn mail', \
    'heb ik iets van X' of 'wat is er binnengekomen'. Vat daarna zelf samen.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "unread_only":{"type":"boolean","description":"Alleen ongelezen berichten. Standaard true."},
      "limit":{"type":"integer","description":"Maximaal aantal berichten, standaard 10, maximaal 50."},
      "search":{"type":"string","description":"Zoekterm die in de afzender of het onderwerp moet voorkomen."}},
     "required":[]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let unreadOnly = arguments["unread_only"] as? Bool ?? true
        let limit = min(arguments.int("limit", default: 10), 50)
        let search = arguments.string("search")

        switch Self.locateIndex() {
        case let .found(path):
            return try await read(index: path,
                                  unreadOnly: unreadOnly, limit: limit, search: search)
        case .needsFullDiskAccess:
            throw ToolError.unavailable("""
            Geen toegang tot je mail. Zet NotchAI aan bij Systeeminstellingen → \
            Privacy en beveiliging → Volledige schijftoegang, en start de app opnieuw.
            """)
        case .noMail:
            throw ToolError.unavailable("Er is geen Mail-account ingesteld op deze Mac.")
        }
    }

    private func read(index: String, unreadOnly: Bool, limit: Int, search: String?) async throws -> String {

        var conditions = ["m.deleted = 0"]
        if unreadOnly { conditions.append("m.read = 0") }
        if let search, !search.isEmpty {
            // Single-quote escaping only; the value never reaches a shell —
            // sqlite3 is invoked with an argument array.
            let escaped = search.replacingOccurrences(of: "'", with: "''")
            conditions.append("(a.address LIKE '%\(escaped)%' OR a.comment LIKE '%\(escaped)%' OR s.subject LIKE '%\(escaped)%')")
        }

        let sql = """
        SELECT
          COALESCE(NULLIF(a.comment,''), a.address, '?'),
          COALESCE(NULLIF(s.subject,''), '(geen onderwerp)'),
          datetime(m.date_received, 'unixepoch', 'localtime'),
          CASE m.read WHEN 0 THEN 'ongelezen' ELSE 'gelezen' END
        FROM messages m
        LEFT JOIN addresses a ON a.ROWID = m.sender
        LEFT JOIN subjects  s ON s.ROWID = m.subject
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY m.date_received DESC
        LIMIT \(limit);
        """

        let countSQL = """
        SELECT COUNT(*) FROM messages m
        LEFT JOIN addresses a ON a.ROWID = m.sender
        LEFT JOIN subjects  s ON s.ROWID = m.subject
        WHERE \(conditions.joined(separator: " AND "));
        """

        let uri = "file:\(index)?immutable=1"
        let result = try await Shell.capture(
            "/usr/bin/sqlite3", ["-separator", " | ", uri, countSQL + "\n" + sql], timeout: 25)

        guard result.status == 0 else {
            // Reading ~/Library/Mail is behind Full Disk Access; without it the
            // open fails with a permission error rather than a prompt.
            if result.combined.lowercased().contains("unable to open") ||
               result.combined.lowercased().contains("authorization denied") {
                throw ToolError.unavailable("""
                Geen toegang tot de mailindex. Geef NotchAI Volledige Schijftoegang in \
                Systeeminstellingen → Privacy en beveiliging → Volledige schijftoegang.
                """)
            }
            throw ToolError.unavailable("Kon de mailindex niet lezen: \(result.combined.prefix(160))")
        }

        var lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !lines.isEmpty else { return "Geen berichten gevonden." }

        let total = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        let body = lines.filter { !$0.isEmpty }
        guard !body.isEmpty else {
            return unreadOnly ? "Geen ongelezen berichten." : "Geen berichten gevonden."
        }

        let scope = unreadOnly ? "ongelezen" : "berichten"
        return "\(total) \(scope) in totaal, hieronder de \(body.count) nieuwste:\n"
            + body.joined(separator: "\n")
    }

    enum Location {
        case found(String)
        case needsFullDiskAccess
        case noMail
    }

    /// Mail versions its container directory (V9, V10, …); take the newest.
    ///
    /// `~/Library/Mail` is TCC-protected, and without Full Disk Access even
    /// *listing* it fails — indistinguishable from "the folder isn't there"
    /// unless you check separately. Reporting the wrong one sent the model off
    /// offering to set up a mail account that already exists.
    static func locateIndex() -> Location {
        let manager = FileManager.default
        let mail = manager.homeDirectoryForCurrentUser.appending(path: "Library/Mail")

        guard let versions = try? manager.contentsOfDirectory(atPath: mail.path) else {
            // The directory is present on every Mac that has ever opened Mail,
            // so a failure to list it is a permission problem, not a missing
            // account — TCC makes the two look identical from here.
            return .needsFullDiskAccess
        }

        let candidates = versions
            .filter { $0.hasPrefix("V") }
            .sorted()
            .reversed()
            .map { mail.appending(path: "\($0)/MailData/Envelope Index").path }

        guard let path = candidates.first(where: { manager.fileExists(atPath: $0) }) else {
            return candidates.isEmpty ? .noMail : .needsFullDiskAccess
        }
        return .found(path)
    }
}

/// Composing rather than sending.
///
/// Outbound mail is the one place where a human should always press the button,
/// and Mail's scripting channel is dead here anyway. Opening a prefilled compose
/// window gets the drafting benefit with none of the "the AI emailed my client"
/// risk.
struct ComposeMailTool: Tool {
    let activityLabel = "Stelt een mail op"
    let name = "compose_mail"
    let description = """
    Opent een nieuw mailvenster met ontvanger, onderwerp en tekst alvast ingevuld. \
    De gebruiker verstuurt zelf. Gebruik dit als er een mail geschreven moet worden.
    """
    let risk = ToolRisk.mutating
    let parametersJSON = """
    {"type":"object","properties":{
      "to":{"type":"string","description":"E-mailadres van de ontvanger."},
      "subject":{"type":"string","description":"Onderwerp."},
      "body":{"type":"string","description":"De tekst van de mail."}},
     "required":["to","subject","body"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let to = try arguments.requiredString("to")
        let subject = arguments.string("subject", default: "")
        let body = arguments.string("body", default: "")

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        guard let url = components.url else {
            throw ToolError.unavailable("Kon geen geldig mailadres maken van '\(to)'.")
        }

        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else {
            throw ToolError.unavailable("Kon geen mailvenster openen.")
        }
        return "Mailvenster geopend aan \(to) met onderwerp '\(subject)'. De gebruiker verstuurt zelf."
    }
}
