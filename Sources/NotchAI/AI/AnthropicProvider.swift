import Foundation

/// Anthropic Messages API (`POST /v1/messages`), streamed over SSE.
///
/// There is no official Anthropic SDK for Swift, so this speaks raw HTTP — the
/// documented fallback for languages without one.
struct AnthropicProvider: LLMProvider {
    let id = ProviderID.anthropic
    let defaultModel = "claude-opus-5"

    private let baseURL = URL(string: "https://api.anthropic.com/v1")!
    private let apiVersion = "2023-06-01"

    /// Server-side refusal fallback: Claude Opus 5's safety classifiers can
    /// decline a request, and `"default"` lets the API re-run it on Anthropic's
    /// recommended model instead of handing us an empty answer.
    private let fallbackBeta = "server-side-fallback-2026-07-01"

    func availableModels() async throws -> [String] {
        // Curated rather than fetched: the notch only ever needs short answers,
        // so the useful choice is a capability/latency tier, not a full catalog.
        ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]
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

                    // Anthropic takes the system prompt as a top-level field,
                    // not as a message with role "system".
                    let system = messages.filter { $0.role == .system }
                        .map(\.text)
                        .joined(separator: "\n\n")

                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": 2048,
                        "messages": Self.encode(messages.filter { $0.role != .system }),
                        "stream": true,
                        // Adaptive rather than disabled: with thinking off,
                        // Claude occasionally writes a tool call into its
                        // visible text instead of emitting a tool_use block —
                        // the turn then succeeds while the call silently never
                        // runs. Low effort keeps it quick.
                        "thinking": ["type": "adaptive"],
                        "output_config": ["effort": "low"],
                        "fallbacks": "default",
                    ]
                    if !system.isEmpty { body["system"] = system }
                    if !tools.isEmpty {
                        body["tools"] = tools.map { schema in
                            ["name": schema.name,
                             "description": schema.description,
                             "input_schema": schema.parameters]
                        }
                    }

                    var request = URLRequest(url: baseURL.appending(path: "/messages"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(key, forHTTPHeaderField: "x-api-key")
                    request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
                    request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    // Tool arguments arrive as JSON fragments across many
                    // events; collect per block index and emit on block stop.
                    var pending: [Int: (id: String, name: String, json: String)] = [:]

                    for try await line in try await StreamTransport.lines(for: request).lines {
                        guard let payload = StreamTransport.sseData(line),
                              let data = payload.data(using: .utf8),
                              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        let index = event["index"] as? Int ?? 0
                        switch event["type"] as? String {
                        case "content_block_start":
                            guard let block = event["content_block"] as? [String: Any],
                                  block["type"] as? String == "tool_use",
                                  let id = block["id"] as? String,
                                  let name = block["name"] as? String else { break }
                            pending[index] = (id, name, "")

                        case "content_block_delta":
                            guard let delta = event["delta"] as? [String: Any] else { break }
                            if delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String {
                                continuation.yield(.text(text))
                            }
                            if delta["type"] as? String == "input_json_delta",
                               let fragment = delta["partial_json"] as? String {
                                pending[index]?.json += fragment
                            }

                        case "content_block_stop":
                            guard let call = pending.removeValue(forKey: index) else { break }
                            continuation.yield(.toolCall(ToolCall(
                                id: call.id,
                                name: call.name,
                                argumentsJSON: call.json.isEmpty ? "{}" : call.json
                            )))

                        case "message_delta":
                            // A refusal arrives as a normal 200 with this stop
                            // reason — surfacing it beats an empty bubble.
                            if let delta = event["delta"] as? [String: Any],
                               delta["stop_reason"] as? String == "refusal" {
                                throw LLMError.notReachable("Het model heeft dit verzoek geweigerd.")
                            }

                        default:
                            break
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

    /// Anthropic models tool results as *user* turns carrying `tool_result`
    /// blocks, so consecutive results have to be merged into one message.
    private static func encode(_ messages: [ChatMessage]) -> [[String: Any]] {
        var encoded: [[String: Any]] = []

        for message in messages {
            switch message.role {
            case .tool:
                let block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": message.toolCallID ?? "",
                    "content": message.text,
                ]
                if var last = encoded.last,
                   last["role"] as? String == "user",
                   var content = last["content"] as? [[String: Any]] {
                    content.append(block)
                    last["content"] = content
                    encoded[encoded.count - 1] = last
                } else {
                    encoded.append(["role": "user", "content": [block]])
                }

            case .assistant where !message.toolCalls.isEmpty:
                var content: [[String: Any]] = []
                if !message.text.isEmpty {
                    content.append(["type": "text", "text": message.text])
                }
                for call in message.toolCalls {
                    content.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": call.arguments,
                    ])
                }
                encoded.append(["role": "assistant", "content": content])

            default:
                encoded.append(["role": message.role.rawValue, "content": message.text])
            }
        }
        return encoded
    }
}
