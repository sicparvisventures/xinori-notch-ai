import Foundation

/// Which model a role runs on. Resolved to an actual tag through `Settings`, so
/// the same architecture works with everything local or with a cloud
/// orchestrator over local specialists.
enum ModelTier: String, Sendable {
    /// Narrow scope, three tools, called often — speed matters more than depth.
    case fast
    /// Judgement calls: what a question actually spans, and what the answer is.
    case balanced
}

/// A domain of the Mac, its tools, and the specialist that owns them.
///
/// Grouping is what makes the toolset scale. With twenty-eight tools in one flat
/// list the model's job is "rank these by relevance", which it does badly; with
/// six domains the job is "is this about mail?", which it does well. The obvious
/// alternative — embedding tool descriptions and retrieving the top-k — is
/// measurably worse: the ACL-2025 ToolRet benchmark shows generic retrieval
/// models underperform on tool retrieval, because they are trained on prose and
/// a tool match often hinges on parameters rather than words.
enum ToolDomain: String, CaseIterable, Sendable {
    case mail
    case agenda
    case bestanden
    case systeem
    case geheugen
    case shortcuts

    var displayName: String {
        switch self {
        case .mail: return "Mail"
        case .agenda: return "Agenda"
        case .bestanden: return "Bestanden"
        case .systeem: return "Systeem"
        case .geheugen: return "Geheugen"
        case .shortcuts: return "Shortcuts"
        }
    }

    /// What the orchestrator reads when deciding where to send a task. Written
    /// for that decision — concrete nouns, no capability boasting.
    var summary: String {
        switch self {
        case .mail:
            return "E-mail en berichten: inbox lezen, zoeken op afzender of onderwerp, iMessage en sms doorzoeken, een mail opstellen."
        case .agenda:
            return "Agenda en taken: afspraken opzoeken, een afspraak inplannen, herinneringen bekijken en toevoegen, contacten opzoeken."
        case .bestanden:
            return "Bestanden: zoeken op naam, inhoud of type, mappen bekijken, tekst en spreadsheets lezen, bestanden schrijven of naar de prullenmand verplaatsen."
        case .systeem:
            return "Deze Mac zelf: batterij, schijf en geheugen, welke apps draaien, apps activeren of sluiten, geplande taken, shell-commando's."
        case .geheugen:
            return "Notities en geschiedenis: Apple Notes doorzoeken en lezen, een notitie maken, browsergeschiedenis, klembord."
        case .shortcuts:
            return "Shortcuts van de gebruiker: zien welke er zijn en er een uitvoeren."
        }
    }

    var tools: [any Tool] {
        let all = ToolRegistry.shared.tools
        func pick(_ names: [String]) -> [any Tool] {
            names.compactMap { name in all.first { $0.name == name } }
        }
        switch self {
        case .mail:
            return pick(["list_mail", "search_messages", "compose_mail"])
        case .agenda:
            return pick(["list_calendar", "create_calendar_event",
                         "list_reminders", "create_reminder", "search_contacts"])
        case .bestanden:
            return pick(["search_files", "list_directory", "read_file",
                         "read_spreadsheet", "write_file", "move_to_trash", "open_path"])
        case .systeem:
            return pick(["system_info", "list_apps", "frontmost_app", "control_app",
                         "list_scheduled_jobs", "schedule_job", "run_shell"])
        case .geheugen:
            return pick(["search_notes", "read_note", "create_note",
                         "browser_history", "clipboard_read", "clipboard_write"])
        case .shortcuts:
            return pick(["list_shortcuts", "run_shortcut"])
        }
    }

    var tier: ModelTier {
        switch self {
        // These two carry the riskiest tools and the vaguest questions, so they
        // get the model that can actually weigh a choice.
        case .systeem, .geheugen: return .balanced
        default: return .fast
        }
    }

    /// A specialist that wanders is worse than one that gives up. Three rounds
    /// is enough for look-something-up-then-act.
    var maxRounds: Int { 3 }

    var systemPrompt: String {
        """
        Je bent de \(displayName)-specialist van een assistent op een Mac. Je krijgt \
        één afgebakende opdracht van de orchestrator en voert die uit met je eigen tools.

        \(summary)

        Werkwijze:
        - Roep de tools aan die je nodig hebt en stop zodra je de opdracht kunt beantwoorden.
        - Noem concrete namen, paden, datums en afzenders uit de tool-uitvoer. Verzin nooit \
          een naam of een waarde die niet in het resultaat stond.
        - Kun je de opdracht niet uitvoeren, zeg dan in één zin waarom.

        Formaat van je antwoord — dit is strikt:
        - Alleen het resultaat. Geen inleiding, geen redenering, geen beschrijving van wat \
          je gaat doen of gedaan hebt.
        - Begin nooit met "Okay", "Let me", "I called", "De gebruiker vroeg" of iets \
          vergelijkbaars.
        - Maximaal drie zinnen, of een korte opsomming als het om een lijst gaat.

        Je antwoord gaat rechtstreeks naar de orchestrator, die er de gebruiker mee \
        antwoordt. Alles wat jij erbij verzint, verzint hij ook.
        """
    }

    /// The tool name the orchestrator calls to reach this specialist.
    var delegateName: String { "delegate_\(rawValue)" }

    var delegateSchema: ToolSchema {
        ToolSchema(
            name: delegateName,
            description: """
            Geef een opdracht aan de \(displayName)-specialist. \(summary) \
            Beschrijf de opdracht volledig in één zin — de specialist ziet het gesprek niet.
            """,
            parametersJSON: """
            {"type":"object","properties":{
              "task":{"type":"string","description":"De opdracht, volledig en op zichzelf staand."}},
             "required":["task"]}
            """)
    }

    static func domain(forDelegate name: String) -> ToolDomain? {
        allCases.first { $0.delegateName == name }
    }
}
