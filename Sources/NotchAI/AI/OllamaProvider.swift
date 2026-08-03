import Foundation

/// Local inference through the Ollama daemon on `:11434`.
///
/// Two request knobs matter for how this *feels*:
/// - `keep_alive: -1` pins the model in memory, so there is no load stall
///   between opening the notch and the first token.
/// - `think: false` disables Qwen3's reasoning pass; we'd only be waiting on
///   tokens we never display.
struct OllamaProvider: LLMProvider {
    let id = ProviderID.ollama
    let defaultModel = "qwen3:8b"
    var baseURL = URL(string: "http://127.0.0.1:11434")!

    func availableModels() async throws -> [String] {
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: baseURL.appending(path: "/api/tags"))
            return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name).sorted()
        } catch {
            throw LLMError.notReachable("Ollama niet bereikbaar op \(baseURL.absoluteString). Draait `ollama serve`?")
        }
    }

    func stream(
        messages: [ChatMessage],
        model: String,
        tools: [ToolSchema]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: [String: Any] = [
                        "model": model,
                        "messages": messages.map(Self.encode),
                        "stream": true,
                        "think": false,
                        "keep_alive": -1,
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

                    var request = URLRequest(url: baseURL.appending(path: "/api/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    // Ollama streams NDJSON: one complete JSON object per line.
                    var index = 0
                    for try await line in try await StreamTransport.lines(for: request).lines {
                        guard !line.isEmpty, let data = line.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let message = object["message"] as? [String: Any] {
                            if let text = message["content"] as? String, !text.isEmpty {
                                continuation.yield(.text(text))
                            }
                            for raw in message["tool_calls"] as? [[String: Any]] ?? [] {
                                guard let function = raw["function"] as? [String: Any],
                                      let name = function["name"] as? String else { continue }
                                index += 1
                                continuation.yield(.toolCall(ToolCall(
                                    // Ollama omits ids on some models; a stable
                                    // local id keeps result pairing intact.
                                    id: raw["id"] as? String ?? "call_\(index)",
                                    name: name,
                                    argumentsJSON: StreamTransport.jsonString(function["arguments"] ?? [:])
                                )))
                            }
                        }
                        if object["done"] as? Bool == true { break }
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
            // Ollama pairs results to calls by tool name, not by id.
            return [
                "role": "tool",
                "tool_name": message.toolName ?? "",
                "content": message.text,
            ]
        case .assistant where !message.toolCalls.isEmpty:
            return [
                "role": "assistant",
                "content": message.text,
                "tool_calls": message.toolCalls.map { call in
                    ["function": ["name": call.name, "arguments": call.arguments]]
                },
            ]
        default:
            return ["role": message.role.rawValue, "content": message.text]
        }
    }
}
