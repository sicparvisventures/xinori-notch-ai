import AppKit
import Foundation

/// Battery, disk and memory. The questions you'd otherwise open three apps for.
struct SystemInfoTool: Tool {
    let activityLabel = "Kijkt naar je systeem"
    let name = "system_info"
    let description = """
    Geeft actuele systeeminformatie van deze Mac: batterij, schijfruimte, geheugen \
    of een overzicht van alles. Gebruik dit voor vragen als 'hoeveel batterij heb ik nog' \
    of 'is mijn schijf vol'.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{"topic":{"type":"string",
     "enum":["battery","disk","memory","all"],
     "description":"Welk onderdeel je wil weten. 'all' geeft alles."}},
     "required":["topic"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let topic = arguments.string("topic", default: "all")
        var parts: [String] = []

        if topic == "battery" || topic == "all" {
            let raw = try await Shell.run("/usr/bin/pmset", ["-g", "batt"])
            parts.append("Batterij:\n" + raw)
        }
        if topic == "disk" || topic == "all" {
            let raw = try await Shell.run("/bin/df", ["-h", "/System/Volumes/Data"])
            parts.append("Schijf:\n" + raw)
        }
        if topic == "memory" || topic == "all" {
            let total = try await Shell.run("/usr/sbin/sysctl", ["-n", "hw.memsize"])
            let gigabytes = (Double(total) ?? 0) / 1_073_741_824
            let pressure = try await Shell.run("/usr/bin/memory_pressure", ["-Q"])
            parts.append(String(format: "Geheugen: %.0f GB totaal\n", gigabytes) + pressure)
        }

        return parts.isEmpty ? "Onbekend onderwerp: \(topic)" : parts.joined(separator: "\n\n")
    }
}

/// Spotlight search. Far faster than walking the filesystem, and it already
/// knows about file contents.
struct SearchFilesTool: Tool {
    let activityLabel = "Zoekt in je bestanden"
    let name = "search_files"
    let description = """
    Zoekt bestanden op deze Mac via Spotlight, op naam, op inhoud of op bestandstype. \
    Gebruik file_extension om alle bestanden van een soort te vinden \
    ("welke Excel-bestanden heb ik" → file_extension: "xlsx"). Noem gevonden bestanden \
    altijd bij naam en pad.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "query":{"type":"string","description":"Waar je op zoekt. Mag leeg zijn als je alleen op file_extension zoekt."},
      "file_extension":{"type":"string","description":"Bestandstype zonder punt, bijvoorbeeld xlsx, pdf, docx."},
      "name_only":{"type":"boolean","description":"True om alleen op bestandsnaam te zoeken in plaats van op inhoud."},
      "scope":{"type":"string","description":"Map om in te zoeken, standaard je thuismap. Gebruik / voor de hele schijf."},
      "limit":{"type":"integer","description":"Maximaal aantal resultaten, standaard 20."}},
     "required":[]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let query = arguments.string("query")?.trimmingCharacters(in: .whitespaces) ?? ""
        let ext = arguments.string("file_extension")?
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ")) ?? ""
        let limit = min(arguments.int("limit", default: 20), 100)
        let nameOnly = arguments["name_only"] as? Bool ?? false
        let scope = (arguments.string("scope") as NSString?)?.expandingTildeInPath
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        guard !query.isEmpty || !ext.isEmpty else {
            throw ToolError.missingArgument("query of file_extension")
        }

        // A raw metadata query rather than the bare-word form: it is the only
        // way to combine "of this type" with "matching this text", and it keeps
        // the extension match exact instead of substring-matching filenames.
        var clauses: [String] = []
        if !ext.isEmpty {
            clauses.append("kMDItemFSName == '*.\(ext)'c")
        }
        if !query.isEmpty {
            clauses.append(nameOnly
                ? "kMDItemFSName == '*\(query)*'c"
                : "(kMDItemTextContent == '*\(query)*'c || kMDItemFSName == '*\(query)*'c)")
        }
        let expression = clauses.joined(separator: " && ")

        let output = try await Shell.run(
            "/usr/bin/mdfind", ["-onlyin", scope, expression], timeout: 30)

        let hits = output.split(separator: "\n").map(String.init)
        guard !hits.isEmpty else {
            let what = ext.isEmpty ? "'\(query)'" : ".\(ext)-bestanden"
            return "Geen \(what) gevonden in \(scope)."
        }
        let shown = hits.prefix(limit)
        return "\(hits.count) gevonden in \(scope)\(hits.count > limit ? ", eerste \(limit)" : ""):\n"
            + shown.joined(separator: "\n")
    }
}

/// What the user is actually looking at — lets the model answer "wat staat er
/// nu open" and reason about context without a screenshot.
struct FrontmostAppTool: Tool {
    let activityLabel = "Kijkt wat er open staat"
    let name = "frontmost_app"
    let description = "Geeft de app die nu op de voorgrond staat en de titel van het actieve venster."
    let risk = ToolRisk.readOnly
    let parametersJSON = #"{"type":"object","properties":{}}"#

    func run(arguments: [String: Any]) async throws -> String {
        let script = """
        tell application "System Events"
            set frontApp to first application process whose frontmost is true
            set appName to name of frontApp
            try
                set windowTitle to name of front window of frontApp
            on error
                set windowTitle to "(geen venster)"
            end try
            return appName & " — " & windowTitle
        end tell
        """
        return try await Shell.osascript(script)
    }
}
