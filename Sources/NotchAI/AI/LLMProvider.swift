import Foundation

// MARK: - Messages

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable {
        case system, user, assistant, tool
    }

    let id: UUID
    let role: Role
    var text: String
    /// Populated on assistant turns where the model asked for tools.
    var toolCalls: [ToolCall]
    /// Set on `.tool` turns: which call this is the result of.
    var toolName: String?
    var toolCallID: String?

    init(id: UUID = UUID(),
         role: Role,
         text: String,
         toolCalls: [ToolCall] = [],
         toolName: String? = nil,
         toolCallID: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolName = toolName
        self.toolCallID = toolCallID
    }
}

/// What a provider emits while generating.
enum StreamEvent: Sendable {
    case text(String)
    case toolCall(ToolCall)
}

// MARK: - Providers

enum ProviderID: String, CaseIterable, Codable, Sendable {
    case ollama, anthropic, openai, moonshot

    var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .moonshot: return "Moonshot"
        }
    }

    /// Local providers need no API key and no network egress.
    var isLocal: Bool { self == .ollama }
}

/// Every provider reduces to the same thing: messages and tool schemas in, a
/// stream of text and tool calls out. Cloud vs. local, SSE vs. NDJSON — all of
/// that stays behind here.
protocol LLMProvider: Sendable {
    var id: ProviderID { get }
    var defaultModel: String { get }

    /// Models the provider will actually accept right now. Ollama reports what
    /// is pulled locally; cloud providers return a curated list.
    func availableModels() async throws -> [String]

    func stream(
        messages: [ChatMessage],
        model: String,
        tools: [ToolSchema]
    ) -> AsyncThrowingStream<StreamEvent, Error>
}

enum LLMError: LocalizedError {
    case badResponse(status: Int, body: String)
    case missingAPIKey(ProviderID)
    case notReachable(String)

    var errorDescription: String? {
        switch self {
        case let .badResponse(status, body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "HTTP \(status)" + (trimmed.isEmpty ? "" : ": \(trimmed.prefix(200))")
        case let .missingAPIKey(provider):
            return "Geen API-key voor \(provider.displayName)."
        case let .notReachable(detail):
            return detail
        }
    }
}

// MARK: - Transport helpers

enum StreamTransport {
    /// Issue the request and hand back its body as lines, failing loudly on a
    /// non-2xx so the error surfaces as text instead of an empty stream.
    static func lines(for request: URLRequest) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.notReachable("Geen HTTP-antwoord van \(request.url?.host() ?? "server").")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw LLMError.badResponse(status: http.statusCode, body: body)
        }
        return bytes
    }

    /// Strip the `data:` prefix from a Server-Sent Events line, or return nil
    /// for the comment/blank/event lines we don't care about.
    static func sseData(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return payload.isEmpty || payload == "[DONE]" ? nil : payload
    }

    /// Re-encode a decoded JSON value as a compact string, for stashing tool
    /// arguments in a `Sendable` field.
    static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
