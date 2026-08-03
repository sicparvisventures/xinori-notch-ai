import Foundation

/// Scheduled jobs through launchd, not cron.
///
/// cron still works on macOS but is deprecated, has no access to the user's GUI
/// session, and is invisible to the system's own job tooling. launchd agents in
/// `~/Library/LaunchAgents` are the supported mechanism and survive reboots.
private let launchAgentsDirectory = FileManager.default
    .homeDirectoryForCurrentUser
    .appending(path: "Library/LaunchAgents")

struct ListScheduledJobsTool: Tool {
    let activityLabel = "Bekijkt je geplande taken"
    let name = "list_scheduled_jobs"
    let description = """
    Geeft de geplande taken (launchd agents) van deze gebruiker: label, wanneer ze \
    draaien en welk commando. Gebruik dit voor 'welke cron jobs heb ik' of \
    'wat draait er automatisch'.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "mine_only":{"type":"boolean","description":"Alleen taken die via NotchAI zijn aangemaakt. Standaard false."}},
     "required":[]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let mineOnly = arguments["mine_only"] as? Bool ?? false
        let manager = FileManager.default

        guard let entries = try? manager.contentsOfDirectory(
            at: launchAgentsDirectory, includingPropertiesForKeys: nil
        ) else {
            return "Geen persoonlijke geplande taken gevonden."
        }

        var described: [String] = []
        for url in entries where url.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, format: nil) as? [String: Any]
            else { continue }

            let label = plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
            if mineOnly && !label.hasPrefix(ScheduleJobTool.labelPrefix) { continue }

            let program = (plist["ProgramArguments"] as? [String])?.joined(separator: " ")
                ?? plist["Program"] as? String
                ?? "(onbekend commando)"

            var when = "handmatig"
            if let interval = plist["StartInterval"] as? Int {
                when = "elke \(interval)s"
            } else if let calendar = plist["StartCalendarInterval"] as? [String: Any] {
                let hour = calendar["Hour"] as? Int
                let minute = calendar["Minute"] as? Int ?? 0
                when = hour.map { String(format: "dagelijks om %02d:%02d", $0, minute) } ?? "op schema"
            } else if plist["RunAtLoad"] as? Bool == true {
                when = "bij inloggen"
            }

            described.append("\(label) | \(when) | \(program)")
        }

        guard !described.isEmpty else { return "Geen persoonlijke geplande taken gevonden." }
        return "\(described.count) geplande taken:\n" + described.sorted().joined(separator: "\n")
    }
}

/// Creating a job writes a file and loads it into the user's launchd domain —
/// squarely mutating, so it never runs without confirmation.
struct ScheduleJobTool: Tool {
    let activityLabel = "Maakt een geplande taak"
    static let labelPrefix = "com.xinori.notchai.job."

    let name = "schedule_job"
    let description = """
    Maakt een terugkerende taak aan die automatisch draait, ook na herstarten. \
    Geef of een interval in seconden, of een tijdstip (uur en minuut) voor dagelijks draaien. \
    Gebruik dit voor 'draai dit script elke ochtend om 8 uur'.
    """
    let risk = ToolRisk.mutating
    let parametersJSON = """
    {"type":"object","properties":{
      "label":{"type":"string","description":"Korte unieke naam, bijvoorbeeld 'backup-notities'."},
      "command":{"type":"string","description":"Het shell-commando dat moet draaien."},
      "interval_seconds":{"type":"integer","description":"Draai elke N seconden. Gebruik dit óf hour/minute, niet beide."},
      "hour":{"type":"integer","description":"Uur van de dag (0-23) voor dagelijks draaien."},
      "minute":{"type":"integer","description":"Minuut (0-59), standaard 0."}},
     "required":["label","command"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let rawLabel = try arguments.requiredString("label")
        let command = try arguments.requiredString("command")

        // Namespaced and sanitised: the label becomes a filename and a launchd
        // identifier, so anything path-like has to go.
        let safeLabel = rawLabel
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let label = Self.labelPrefix + safeLabel

        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/zsh", "-lc", command],
            "RunAtLoad": false,
            "StandardOutPath": "/tmp/\(label).out.log",
            "StandardErrorPath": "/tmp/\(label).err.log",
        ]

        var schedule: String
        if let interval = arguments["interval_seconds"] as? Int, interval > 0 {
            plist["StartInterval"] = interval
            schedule = "elke \(interval) seconden"
        } else if let hour = arguments["hour"] as? Int {
            let minute = arguments.int("minute", default: 0)
            plist["StartCalendarInterval"] = ["Hour": hour, "Minute": minute]
            schedule = String(format: "dagelijks om %02d:%02d", hour, minute)
        } else {
            throw ToolError.missingArgument("interval_seconds of hour")
        }

        try FileManager.default.createDirectory(
            at: launchAgentsDirectory, withIntermediateDirectories: true)
        let url = launchAgentsDirectory.appending(path: "\(label).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)

        // Replace any previous incarnation before loading, otherwise bootstrap
        // fails with "service already loaded".
        let domain = "gui/\(getuid())"
        _ = try? await Shell.capture("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        _ = try await Shell.run("/bin/launchctl", ["bootstrap", domain, url.path])

        return "Taak '\(label)' aangemaakt: \(schedule). Commando: \(command)"
    }
}
