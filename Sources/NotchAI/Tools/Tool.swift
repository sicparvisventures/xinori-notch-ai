import Foundation

/// A tool call as requested by the model.
///
/// Arguments stay as raw JSON rather than a dictionary so the type remains
/// `Sendable` and `Equatable` — it travels through an `AsyncStream` and lands in
/// `@Published` state.
struct ToolCall: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: String

    var arguments: [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// Compact one-line rendering for the confirmation prompt.
    var summary: String {
        let pairs = arguments
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: ", ")
        return pairs.isEmpty ? name : "\(name)(\(pairs))"
    }
}

/// How much damage a tool can do if the model gets it wrong.
enum ToolRisk: Sendable {
    /// Reads state only. Runs without asking.
    case readOnly
    /// Changes something, sends something, or runs arbitrary code. Always asks
    /// first — an LLM driving your Mac needs a human in the loop for these.
    case mutating
}

protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON Schema for the arguments, as a JSON string.
    var parametersJSON: String { get }
    var risk: ToolRisk { get }

    func run(arguments: [String: Any]) async throws -> String

    /// Shown live while the tool runs — "Leest je mail…" tells the user more
    /// than a spinner does.
    var activityLabel: String { get }
}

extension Tool {
    var schema: ToolSchema {
        ToolSchema(name: name, description: description, parametersJSON: parametersJSON)
    }

    var activityLabel: String { "Voert \(name) uit" }
}

/// The provider-facing view of a tool: everything needed to describe it to a
/// model, and nothing that can execute.
struct ToolSchema: Sendable {
    let name: String
    let description: String
    let parametersJSON: String

    var parameters: [String: Any] {
        guard let data = parametersJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ["type": "object", "properties": [:]] }
        return object
    }
}

// MARK: - Argument helpers

extension [String: Any] {
    func string(_ key: String) -> String? {
        self[key] as? String
    }

    func string(_ key: String, default fallback: String) -> String {
        string(key) ?? fallback
    }

    func int(_ key: String, default fallback: Int) -> Int {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        if let value = self[key] as? String, let parsed = Int(value) { return parsed }
        return fallback
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else {
            throw ToolError.missingArgument(key)
        }
        return value
    }
}

enum ToolError: LocalizedError {
    case missingArgument(String)
    case unknownTool(String)
    case declined(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(key): return "Verplicht argument '\(key)' ontbreekt."
        case let .unknownTool(name): return "Onbekende tool '\(name)'."
        case let .declined(name): return "De gebruiker heeft '\(name)' geweigerd."
        case let .unavailable(reason): return reason
        }
    }
}


/// Four different tools read four different TCC-protected stores, and each one
/// fails in its own dialect: sqlite3 says "unable to open database file", Python
/// raises `OperationalError`, Foundation returns a permission error. Left to
/// themselves they surface as gibberish, and the model then invents an
/// explanation — it once offered to set up a mail account that already existed.
enum FullDiskAccess {
    static func looksDenied(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("unable to open database")
            || lowered.contains("operationalerror")
            || lowered.contains("authorization denied")
            || lowered.contains("operation not permitted")
            || lowered.contains("permission denied")
    }

    static func error(_ source: String) -> ToolError {
        .unavailable("""
        Geen toegang tot \(source). Zet NotchAI aan bij Systeeminstellingen → \
        Privacy en beveiliging → Volledige schijftoegang, en start de app opnieuw.
        """)
    }
}
