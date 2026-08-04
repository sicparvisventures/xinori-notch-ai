import AppKit
import Contacts
import Foundation

/// Contacts through the framework rather than the AddressBook files — it asks
/// for consent properly and survives the storage format changing under us.
struct ListContactsTool: Tool {
    let activityLabel = "Zoekt een contact"
    let name = "search_contacts"
    let description = """
    Zoekt in je contacten op naam en geeft telefoonnummers en e-mailadressen terug. \
    Gebruik dit voor 'wat is het nummer van X'.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "name":{"type":"string","description":"(Deel van) de naam."}},
     "required":["name"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let name = try arguments.requiredString("name")
        let store = CNContactStore()

        guard try await store.requestAccess(for: .contacts) else {
            throw ToolError.unavailable(
                "Geen toegang tot contacten. Sta NotchAI toe in Systeeminstellingen → Privacy en beveiliging → Contacten.")
        }

        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        ].map { $0 as CNKeyDescriptor }

        let matches = try store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)

        guard !matches.isEmpty else { return "Geen contact gevonden met '\(name)'." }

        let lines = matches.prefix(10).map { contact -> String in
            let full = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }.joined(separator: " ")
            let org = contact.organizationName.isEmpty ? "" : " (\(contact.organizationName))"
            let phones = contact.phoneNumbers.map(\.value.stringValue)
            let mails = contact.emailAddresses.map { $0.value as String }
            let details = (phones + mails).joined(separator: ", ")
            return "\(full)\(org)\(details.isEmpty ? "" : " — \(details)")"
        }
        return "\(matches.count) contacten:\n" + lines.joined(separator: "\n")
    }
}

/// Shortcuts is the escape hatch that needs no code.
///
/// Anything the user can build in the Shortcuts app becomes callable here, which
/// makes the toolset extensible without shipping a new tool for every idea — and
/// without letting the model author its own capabilities, since the user built
/// the Shortcut themselves.
struct ListShortcutsTool: Tool {
    let activityLabel = "Bekijkt je Shortcuts"
    let name = "list_shortcuts"
    let description = """
    Geeft de Shortcuts die op deze Mac staan. Gebruik dit om te zien of er al een \
    Shortcut bestaat voor wat de gebruiker vraagt, voordat je iets anders probeert.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = #"{"type":"object","properties":{}}"#

    func run(arguments: [String: Any]) async throws -> String {
        let output = try await Shell.run("/usr/bin/shortcuts", ["list"], timeout: 25)
        let names = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !names.isEmpty else { return "Geen Shortcuts gevonden." }
        return "\(names.count) Shortcuts:\n" + names.joined(separator: "\n")
    }
}

struct RunShortcutTool: Tool {
    let activityLabel = "Draait een Shortcut"
    let name = "run_shortcut"
    let description = """
    Voert een Shortcut uit, optioneel met invoer. Roep eerst list_shortcuts aan om \
    de exacte naam te weten. De uitvoer van de Shortcut komt terug als tekst.
    """
    let risk = ToolRisk.mutating
    let parametersJSON = """
    {"type":"object","properties":{
      "name":{"type":"string","description":"Exacte naam van de Shortcut."},
      "input":{"type":"string","description":"Tekstinvoer voor de Shortcut, optioneel."}},
     "required":["name"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let name = try arguments.requiredString("name")
        var args = ["run", name]

        // Input travels through a temp file: passing it inline would put user
        // text on a command line, and shortcuts reads stdin unreliably.
        var inputURL: URL?
        if let input = arguments.string("input"), !input.isEmpty {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "notchai-shortcut-\(UUID().uuidString).txt")
            try input.write(to: url, atomically: true, encoding: .utf8)
            inputURL = url
            args += ["--input-path", url.path]
        }
        defer { if let inputURL { try? FileManager.default.removeItem(at: inputURL) } }

        let result = try await Shell.capture("/usr/bin/shortcuts", args, timeout: 90)
        guard result.status == 0 else {
            throw ToolError.unavailable("Shortcut '\(name)' faalde: \(result.combined.prefix(200))")
        }
        let output = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "Shortcut '\(name)' uitgevoerd." : "Shortcut '\(name)':\n\(output)"
    }
}

struct ClipboardReadTool: Tool {
    let activityLabel = "Leest je klembord"
    let name = "clipboard_read"
    let description = "Geeft de tekst die nu op het klembord staat."
    let risk = ToolRisk.readOnly
    let parametersJSON = #"{"type":"object","properties":{}}"#

    func run(arguments: [String: Any]) async throws -> String {
        let text = await MainActor.run { NSPasteboard.general.string(forType: .string) }
        guard let text, !text.isEmpty else { return "Het klembord bevat geen tekst." }
        return text.count > 4000 ? String(text.prefix(4000)) + "\n… (afgekapt)" : text
    }
}

struct ClipboardWriteTool: Tool {
    let activityLabel = "Zet iets op je klembord"
    let name = "clipboard_write"
    let description = """
    Zet tekst op het klembord zodat de gebruiker het ergens anders kan plakken. \
    Handig als je iets hebt opgesteld dat elders moet.
    """
    let risk = ToolRisk.mutating
    let parametersJSON = """
    {"type":"object","properties":{
      "text":{"type":"string","description":"Wat er op het klembord moet."}},
     "required":["text"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let text = try arguments.requiredString("text")
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        return "\(text.count) tekens op het klembord gezet."
    }
}

/// Safari history. Chrome and Arc keep their own stores; this covers the one
/// that ships with the machine.
struct BrowserHistoryTool: Tool {
    let activityLabel = "Zoekt in je geschiedenis"
    let name = "browser_history"
    let description = """
    Zoekt in je Safari-geschiedenis op titel of adres. \
    Gebruik dit voor 'die pagina van gisteren over X'.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "query":{"type":"string","description":"Woorden uit de titel of het adres."},
      "limit":{"type":"integer","description":"Maximaal aantal, standaard 12."}},
     "required":[]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let query = arguments.string("query") ?? ""
        let limit = min(arguments.int("limit", default: 12), 40)

        let db = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Safari/History.db")
        guard FileManager.default.fileExists(atPath: db.path) else {
            throw ToolError.unavailable(
                "Geen toegang tot je Safari-geschiedenis (Volledige Schijftoegang nodig).")
        }

        let escaped = query.replacingOccurrences(of: "'", with: "''")
        let filter = query.isEmpty ? "1=1"
            : "(i.url LIKE '%\(escaped)%' OR v.title LIKE '%\(escaped)%')"

        let sql = """
        SELECT datetime(v.visit_time + 978307200, 'unixepoch', 'localtime'),
               COALESCE(NULLIF(v.title,''), '(geen titel)'),
               substr(i.url, 1, 120)
        FROM history_visits v
        JOIN history_items i ON i.id = v.history_item
        WHERE \(filter)
        ORDER BY v.visit_time DESC
        LIMIT \(limit);
        """

        let result = try await Shell.capture(
            "/usr/bin/sqlite3", ["-separator", " | ", "file:\(db.path)?immutable=1", sql],
            timeout: 25)
        guard result.status == 0 else {
            if FullDiskAccess.looksDenied(result.combined) { throw FullDiskAccess.error("je Safari-geschiedenis") }
            throw ToolError.unavailable("Kon de geschiedenis niet lezen: \(result.combined.prefix(160))")
        }
        let lines = result.stdout.split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return "Niets gevonden in je geschiedenis." }
        return "\(lines.count) resultaten:\n" + lines.joined(separator: "\n")
    }
}
