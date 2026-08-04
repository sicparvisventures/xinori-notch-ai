import Foundation

/// One client for every provider that speaks the OpenAI chat-completions
/// dialect. Moonshot (Kimi) is wire-compatible with OpenAI, so it is the same
/// implementation pointed at a different host.
struct OpenAICompatibleProvider: LLMProvider {
    let id: ProviderID
    let defaultModel: String
    let baseURL: URL

    static let openAI = OpenAICompatibleProvider(
        id: .openai,
        defaultModel: "gpt-5",
        baseURL: URL(string: "https://api.openai.com/v1")!
    )

    static let moonshot = OpenAICompatibleProvider(
        id: .moonshot,
        defaultModel: "kimi-k2-0905-preview",
        baseURL: URL(string: "https://api.moonshot.ai/v1")!
    )

    /// Fetched live rather than hardcoded — both providers rename and retire
    /// models often enough that a baked-in list goes stale.
    func availableModels() async throws -> [String] {
        struct Models: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        guard let key = KeychainStore.apiKey(for: id) else {
            throw LLMError.missingAPIKey(id)
        }

        var request = URLRequest(url: baseURL.appending(path: "/models"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LLMError.badResponse(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(Models.self, from: data).data.map(\.id).sorted()
    }

    func stream(
        messages: [ChatMessage],
        model: String,
        tools: [ToolSchema]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let key = KeychainStore.apiKey(for: id) else {
                        throw LLMError.missingAPIKey(id)
                    }

                    var body: [String: Any] = [
                        "model": model,
                        "messages": messages.map(Self.encode),
                        "stream": true,
                        "max_tokens": 2048,
                    ]
                    if !tools.isEmpty {
                        body["tools"] = tools.map { schema in
                            ["type": "function", "function": [
                                "name": schema.name,
                                "description": schema.description,
                                "parameters": schema.parameters,
                            ]]
                        }
                    }

                    var request = URLRequest(url: baseURL.appending(path: "/chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    // Tool calls stream in fragments keyed by index: the name
                    // arrives once, the arguments a few characters at a time.
                    var pending: [Int: (id: String, name: String, json: String)] = [:]

                    for try await line in try await StreamTransport.lines(for: request).lines {
                        guard let payload = StreamTransport.sseData(line),
                              let data = payload.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choice = (object["choices"] as? [[String: Any]])?.first
                        else { continue }

                        if let delta = choice["delta"] as? [String: Any] {
                            if let text = delta["content"] as? String, !text.isEmpty {
                                continuation.yield(.text(text))
                            }
                            for raw in delta["tool_calls"] as? [[String: Any]] ?? [] {
                                let index = raw["index"] as? Int ?? 0
                                let function = raw["function"] as? [String: Any] ?? [:]
                                var entry = pending[index] ?? (id: "", name: "", json: "")
                                if let id = raw["id"] as? String { entry.id = id }
                                if let name = function["name"] as? String { entry.name = name }
                                if let fragment = function["arguments"] as? String { entry.json += fragment }
                                pending[index] = entry
                            }
                        }

                        // Only at finish_reason do we know the fragments are
                        // complete — there is no per-call stop event.
                        if choice["finish_reason"] as? String == "tool_calls" {
                            for (index, call) in pending.sorted(by: { $0.key < $1.key }) {
                                continuation.yield(.toolCall(ToolCall(
                                    id: call.id.isEmpty ? "call_\(index)" : call.id,
                                    name: call.name,
                                    argumentsJSON: call.json.isEmpty ? "{}" : call.json
                                )))
                            }
                            pending.removeAll()
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func encode(_ message: ChatMessage) -> [String: Any] {
        switch message.role {
        case .tool:
            return [
                "role": "tool",
                "tool_call_id": message.toolCallID ?? "",
                "content": message.text,
            ]
        case .assistant where !message.toolCalls.isEmpty:
            return [
                "role": "assistant",
                "content": message.text,
                "tool_calls": message.toolCalls.map { call in
                    ["id": call.id,
                     "type": "function",
                     "function": ["name": call.name, "arguments": call.argumentsJSON]]
                },
            ]
        default:
            return ["role": message.role.rawValue, "content": message.text]
        }
    }
}
