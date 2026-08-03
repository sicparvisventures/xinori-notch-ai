import AppKit
import Foundation

/// Expand `~` and resolve relative paths against home, so the model can hand us
/// what a human would type.
private func resolve(_ path: String) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
    return FileManager.default.homeDirectoryForCurrentUser
        .appending(path: expanded).standardizedFileURL
}

struct ListDirectoryTool: Tool {
    let activityLabel = "Bekijkt een map"
    let name = "list_directory"
    let description = """
    Geeft de inhoud van een map met bestandsnaam, grootte en wijzigingsdatum. \
    Gebruik dit om te zien wat er in een map staat voordat je iets voorstelt. \
    Voorbeelden van paden: ~/Downloads, ~/Documents, /Applications.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "path":{"type":"string","description":"Pad naar de map, bijvoorbeeld ~/Downloads."},
      "limit":{"type":"integer","description":"Maximaal aantal items, standaard 40."}},
     "required":["path"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let url = resolve(try arguments.requiredString("path"))
        let limit = min(arguments.int("limit", default: 40), 200)

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            throw ToolError.unavailable("Kan '\(url.path)' niet lezen. Bestaat de map, en heeft NotchAI toegang?")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let sorted = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let lines = sorted.prefix(limit).map { entry -> String in
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
            let modified = values?.contentModificationDate.map { formatter.string(from: $0) } ?? ""
            return "\(isDirectory ? "[map] " : "")\(entry.lastPathComponent)\(size.isEmpty ? "" : " · \(size)")\(modified.isEmpty ? "" : " · \(modified)")"
        }

        guard !lines.isEmpty else { return "'\(url.path)' is leeg." }
        return "\(url.path) — \(sorted.count) items\(sorted.count > limit ? ", eerste \(limit)" : ""):\n"
            + lines.joined(separator: "\n")
    }
}

struct ReadFileTool: Tool {
    let activityLabel = "Leest een bestand"
    let name = "read_file"
    let description = """
    Leest de inhoud van een tekstbestand (txt, md, csv, json, code, enzovoort). \
    Gebruik dit om echt te kijken wat er in een bestand staat in plaats van te gokken. \
    Voor Excel-bestanden gebruik je read_spreadsheet.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "path":{"type":"string","description":"Pad naar het bestand."},
      "max_characters":{"type":"integer","description":"Maximaal aantal tekens, standaard 6000."}},
     "required":["path"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let url = resolve(try arguments.requiredString("path"))
        let cap = min(arguments.int("max_characters", default: 6000), 20000)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError.unavailable("'\(url.path)' bestaat niet.")
        }
        guard let data = try? Data(contentsOf: url) else {
            throw ToolError.unavailable("Kan '\(url.path)' niet openen.")
        }
        // A binary read back as UTF-8 becomes noise that eats the context
        // window; say so instead.
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError.unavailable(
                "'\(url.lastPathComponent)' is geen tekstbestand. Gebruik read_spreadsheet, of run_shell voor iets anders.")
        }

        if text.count > cap {
            return "\(url.path) (eerste \(cap) van \(text.count) tekens):\n" + String(text.prefix(cap))
        }
        return "\(url.path):\n" + text
    }
}

struct WriteFileTool: Tool {
    let activityLabel = "Schrijft een bestand"
    let name = "write_file"
    let description = """
    Schrijft tekst naar een bestand. Maakt het bestand aan of overschrijft het. \
    Zeg in je antwoord altijd naar welk exact pad je hebt geschreven.
    """
    let risk = ToolRisk.mutating
    let parametersJSON = """
    {"type":"object","properties":{
      "path":{"type":"string","description":"Pad naar het bestand."},
      "content":{"type":"string","description":"De volledige inhoud."},
      "append":{"type":"boolean","description":"True om toe te voegen in plaats van te overschrijven."}},
     "required":["path","content"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let url = resolve(try arguments.requiredString("path"))
        let content = try arguments.requiredString("content")
        let append = arguments["append"] as? Bool ?? false

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if append, let existing = try? String(contentsOf: url, encoding: .utf8) {
            try (existing + content).write(to: url, atomically: true, encoding: .utf8)
            return "Toegevoegd aan \(url.path) (\(content.count) tekens)."
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Geschreven naar \(url.path) (\(content.count) tekens)."
    }
}

struct TrashTool: Tool {
    let activityLabel = "Verplaatst naar prullenmand"
    let name = "move_to_trash"
    let description = """
    Verplaatst een bestand of map naar de prullenmand. Nooit permanent verwijderen — \
    de gebruiker kan het altijd terughalen.
    """
    let risk = ToolRisk.mutating
    let parametersJSON = """
    {"type":"object","properties":{
      "path":{"type":"string","description":"Pad naar wat weg mag."}},
     "required":["path"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let url = resolve(try arguments.requiredString("path"))
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError.unavailable("'\(url.path)' bestaat niet.")
        }
        // The Trash, never unlink: an LLM-driven delete has to be reversible.
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return "'\(url.lastPathComponent)' staat nu in de prullenmand."
    }
}

/// Spreadsheets through Python, because there is no system framework for xlsx
/// and writing a parser here would be a project of its own.
struct ReadSpreadsheetTool: Tool {
    let activityLabel = "Leest een spreadsheet"
    let name = "read_spreadsheet"
    let description = """
    Leest een Excel-bestand (.xlsx) of CSV en geeft de inhoud als tekst terug, \
    inclusief bladnamen en celwaarden. Gebruik dit voordat je iets over de inhoud zegt.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "path":{"type":"string","description":"Pad naar het .xlsx- of .csv-bestand."},
      "sheet":{"type":"string","description":"Naam van het blad. Standaard het eerste."},
      "max_rows":{"type":"integer","description":"Maximaal aantal rijen, standaard 50."}},
     "required":["path"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let url = resolve(try arguments.requiredString("path"))
        let maxRows = min(arguments.int("max_rows", default: 50), 500)
        let sheet = arguments.string("sheet") ?? ""

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError.unavailable("'\(url.path)' bestaat niet.")
        }

        if url.pathExtension.lowercased() == "csv" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let rows = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxRows)
            return "\(url.lastPathComponent) (CSV, eerste \(rows.count) rijen):\n"
                + rows.joined(separator: "\n")
        }

        let script = """
        import sys, json
        try:
            import openpyxl
        except ImportError:
            print("MISSING_OPENPYXL"); sys.exit(0)
        wb = openpyxl.load_workbook(sys.argv[1], data_only=True, read_only=True)
        want = sys.argv[2]
        ws = wb[want] if want and want in wb.sheetnames else wb[wb.sheetnames[0]]
        print("Bladen: " + ", ".join(wb.sheetnames))
        print("Actief blad: " + ws.title)
        for i, row in enumerate(ws.iter_rows(values_only=True)):
            if i >= int(sys.argv[3]): break
            print(" | ".join("" if c is None else str(c) for c in row))
        """
        let result = try await Shell.capture(
            "/usr/bin/env", ["python3", "-c", script, url.path, sheet, String(maxRows)], timeout: 45)

        if result.stdout.contains("MISSING_OPENPYXL") {
            throw ToolError.unavailable(
                "Om Excel-bestanden te lezen is openpyxl nodig. Installeer het met: pip3 install openpyxl")
        }
        guard result.status == 0 else {
            throw ToolError.unavailable("Kon het bestand niet lezen: \(result.combined.prefix(200))")
        }
        return "\(url.path)\n" + result.stdout
    }
}

struct OpenPathTool: Tool {
    let activityLabel = "Opent iets"
    let name = "open_path"
    let description = """
    Opent een bestand, map of URL in de standaard-app, of toont het in de Finder. \
    Gebruik dit als de gebruiker iets wil zien in plaats van erover wil lezen.
    """
    let risk = ToolRisk.mutating
    let parametersJSON = """
    {"type":"object","properties":{
      "path":{"type":"string","description":"Pad of URL."},
      "reveal":{"type":"boolean","description":"True om in de Finder te tonen in plaats van te openen."}},
     "required":["path"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let raw = try arguments.requiredString("path")
        let reveal = arguments["reveal"] as? Bool ?? false

        if raw.hasPrefix("http://") || raw.hasPrefix("https://"), let url = URL(string: raw) {
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
            return "\(raw) geopend."
        }

        let url = resolve(raw)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError.unavailable("'\(url.path)' bestaat niet.")
        }
        await MainActor.run {
            if reveal {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return reveal ? "\(url.path) getoond in de Finder." : "\(url.path) geopend."
    }
}
