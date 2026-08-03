import AppKit
import Foundation

/// What is installed and what is running — the difference between "ik kan geen
/// apps zien" and "Numbers staat op je Mac, wil je dat ik het daarin open".
struct ListAppsTool: Tool {
    let activityLabel = "Bekijkt je apps"
    let name = "list_apps"
    let description = """
    Geeft de apps op deze Mac: welke geïnstalleerd zijn en welke nu draaien. \
    Gebruik dit voordat je zegt dat iets niet kan — misschien staat de juiste app er wel.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "running_only":{"type":"boolean","description":"Alleen de apps die nu draaien."},
      "filter":{"type":"string","description":"Toon alleen apps waarvan de naam dit bevat."}},
     "required":[]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let runningOnly = arguments["running_only"] as? Bool ?? false
        let filter = arguments.string("filter")?.lowercased()

        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications
                .compactMap(\.localizedName)
        }
        let runningSet = Set(running)

        if runningOnly {
            let names = matching(running.sorted(), filter)
            return names.isEmpty ? "Geen draaiende apps gevonden." :
                "\(names.count) draaiende apps:\n" + names.joined(separator: ", ")
        }

        var installed: [String] = []
        for directory in ["/Applications", "/System/Applications",
                          NSHomeDirectory() + "/Applications"] {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            installed += contents
                .filter { $0.hasSuffix(".app") }
                .map { String($0.dropLast(4)) }
        }

        let names = matching(Array(Set(installed)).sorted(), filter)
        guard !names.isEmpty else { return "Geen apps gevonden." }

        let annotated = names.prefix(80).map { runningSet.contains($0) ? "\($0) (draait)" : $0 }
        return "\(names.count) apps:\n" + annotated.joined(separator: ", ")
    }

    private func matching(_ names: [String], _ filter: String?) -> [String] {
        guard let filter, !filter.isEmpty else { return names }
        return names.filter { $0.lowercased().contains(filter) }
    }
}

/// Bringing an app forward or quitting it. Mutating: quitting an app with
/// unsaved work is exactly the kind of thing you want to be asked about.
struct ControlAppTool: Tool {
    let activityLabel = "Bestuurt een app"
    let name = "control_app"
    let description = """
    Activeert, opent of sluit een app op deze Mac. \
    Gebruik de naam zoals hij in de Finder staat, bijvoorbeeld 'Numbers' of 'Safari'.
    """
    let risk = ToolRisk.mutating
    let parametersJSON = """
    {"type":"object","properties":{
      "app":{"type":"string","description":"Naam van de app."},
      "action":{"type":"string","enum":["activate","quit"],"description":"Naar voren halen of afsluiten."}},
     "required":["app","action"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let app = try arguments.requiredString("app")
        let action = arguments.string("action", default: "activate")

        // Quoted inside AppleScript, so a name with a space is fine; the name
        // itself never reaches a shell.
        let escaped = app.replacingOccurrences(of: "\"", with: "\\\"")

        switch action {
        case "quit":
            _ = try await Shell.osascript("tell application \"\(escaped)\" to quit")
            return "\(app) afgesloten."
        default:
            _ = try await Shell.osascript("tell application \"\(escaped)\" to activate")
            return "\(app) staat nu op de voorgrond."
        }
    }
}
