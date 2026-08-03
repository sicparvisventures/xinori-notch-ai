import Foundation
import SwiftUI

/// Owns the conversation, the selected provider/model, and the tool loop.
@MainActor
final class ChatModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var errorText: String?

    /// Set while a mutating tool waits for a human decision. The panel renders
    /// this as an allow/deny prompt and nothing runs until it is answered.
    @Published private(set) var pendingApproval: ToolCall?

    /// What the assistant is doing right now, shown live in the panel.
    /// `nil` once tokens start arriving — the text itself is the signal then.
    @Published private(set) var activity: String?

    @Published var toolsEnabled: Bool {
        didSet { Settings.toolsEnabled = toolsEnabled }
    }

    @Published var providerID: ProviderID {
        didSet {
            guard providerID != oldValue else { return }
            model = Settings.model(for: providerID) ?? provider.defaultModel
            Settings.providerID = providerID
            Task { await refreshModels() }
        }
    }

    @Published var model: String {
        didSet { Settings.setModel(model, for: providerID) }
    }

    @Published private(set) var availableModels: [String] = []

    private var streamTask: Task<Void, Never>?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?

    /// How many times the model may call tools and be fed results before we
    /// stop. Without a ceiling a confused model can loop indefinitely.
    private let maxToolRounds = 6

    private var systemPrompt: ChatMessage {
        ChatMessage(role: .system, text: """
        Je bent een assistent die vanuit de notch van een MacBook antwoordt en \
        toegang heeft tot deze Mac via tools.

        Het venster is klein en antwoorden worden vaak voorgelezen. Antwoord kort \
        en direct — meestal één tot drie zinnen. Geen markdown-opmaak, geen \
        opsommingen tenzij er expliciet om gevraagd wordt. Spreek de taal van de gebruiker.

        Gebruik tools wanneer de vraag over de actuele staat van deze Mac gaat \
        (mail, agenda, bestanden, apps, systeem, geplande taken) in plaats van te gokken \
        of te zeggen dat je er geen toegang toe hebt. Vat resultaten samen in gewone \
        taal — plak nooit de ruwe uitvoer over.

        Antwoord concreet, nooit in mogelijkheden. Zeg niet "ja, dat kan ik" — kijk \
        eerst en noem dan het echte bestand, pad, blad of programma. Als de gebruiker \
        iets vraagt over een bestandssoort, zoek dan met search_files of list_directory \
        welke bestanden dat zijn en noem ze bij naam en pad. Als er niets is, zeg dat, \
        en bied aan er een te maken.
        """)
    }

    init() {
        let stored = Settings.providerID
        providerID = stored
        model = Settings.model(for: stored) ?? ProviderRegistry.provider(for: stored).defaultModel
        toolsEnabled = Settings.toolsEnabled
        Task { await refreshModels() }
    }

    var provider: any LLMProvider { ProviderRegistry.provider(for: providerID) }

    /// The full text of the most recent assistant turn — what speech output reads.
    var lastAssistantText: String? {
        messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text
    }

    // MARK: - Models

    func refreshModels() async {
        do {
            availableModels = try await provider.availableModels()
            // A model that vanished (unpulled, renamed) would fail silently at
            // send time; fall back now while we can still say why.
            if !availableModels.isEmpty, !availableModels.contains(model) {
                model = availableModels.first ?? provider.defaultModel
            }
            errorText = nil
        } catch {
            availableModels = []
            errorText = error.localizedDescription
        }
    }

    // MARK: - Sending

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isStreaming else { return }

        errorText = nil
        messages.append(ChatMessage(role: .user, text: prompt))
        isStreaming = true

        let provider = self.provider
        let model = self.model
        let tools = toolsEnabled ? ToolRegistry.shared.schemas : []

        streamTask = Task { [weak self] in
            await self?.runConversation(provider: provider, model: model, tools: tools)
            self?.activity = nil
            self?.isStreaming = false
            self?.streamTask = nil
        }
    }

    /// Stream, run any tools the model asks for, feed the results back, repeat.
    private func runConversation(provider: any LLMProvider, model: String, tools: [ToolSchema]) async {
        for round in 0..<maxToolRounds {
            guard !Task.isCancelled else { return }

            let reply = ChatMessage(role: .assistant, text: "")
            messages.append(reply)
            activity = "Denkt na"

            var calls: [ToolCall] = []
            do {
                let history = [systemPrompt] + messages.dropLast()
                for try await event in provider.stream(messages: history, model: model, tools: tools) {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case let .text(delta):
                        activity = nil
                        append(delta, to: reply.id)
                    case let .toolCall(call):
                        calls.append(call)
                    }
                }
            } catch {
                errorText = error.localizedDescription
                activity = nil
                prune(reply.id)
                return
            }

            guard !calls.isEmpty else {
                activity = nil
                prune(reply.id)
                return
            }

            attach(calls, to: reply.id)

            for call in calls {
                guard !Task.isCancelled else { return }
                let output = await execute(call)
                messages.append(ChatMessage(
                    role: .tool, text: output, toolName: call.name, toolCallID: call.id))
            }

            if round == maxToolRounds - 1 {
                errorText = "Gestopt na \(maxToolRounds) tool-rondes."
            }
        }
    }

    /// Read-only tools run straight away; anything that changes state waits for
    /// a human. The model never gets to decide that for itself.
    private func execute(_ call: ToolCall) async -> String {
        let registry = ToolRegistry.shared
        guard let tool = registry.tool(named: call.name) else {
            return ToolError.unknownTool(call.name).localizedDescription
        }
        activity = tool.activityLabel
        if tool.risk == .mutating {
            guard await requestApproval(for: call) else {
                return ToolError.declined(call.name).localizedDescription
            }
        }
        return await registry.run(call)
    }

    // MARK: - Approval

    private func requestApproval(for call: ToolCall) async -> Bool {
        await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            pendingApproval = call
        }
    }

    func resolveApproval(allow: Bool) {
        pendingApproval = nil
        approvalContinuation?.resume(returning: allow)
        approvalContinuation = nil
    }

    // MARK: - Lifecycle

    func cancel() {
        // Resume first: a suspended approval would otherwise leak its
        // continuation and the task would never finish.
        if approvalContinuation != nil { resolveApproval(allow: false) }
        streamTask?.cancel()
        streamTask = nil
        activity = nil
        isStreaming = false
    }

    func reset() {
        cancel()
        messages.removeAll()
        errorText = nil
    }

    // MARK: - Message mutation

    private func append(_ delta: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += delta
    }

    private func attach(_ calls: [ToolCall], to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].toolCalls = calls
    }

    /// An empty assistant bubble after a failure is just noise.
    private func prune(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].text.isEmpty,
              messages[index].toolCalls.isEmpty
        else { return }
        messages.remove(at: index)
    }
}

// MARK: - Registry

enum ProviderRegistry {
    static func provider(for id: ProviderID) -> any LLMProvider {
        switch id {
        case .ollama: return OllamaProvider()
        case .anthropic: return AnthropicProvider()
        case .openai: return OpenAICompatibleProvider.openAI
        case .moonshot: return OpenAICompatibleProvider.moonshot
        }
    }
}

// MARK: - Settings

/// Non-secret preferences. API keys never land here — those go to the Keychain.
enum Settings {
    private static let defaults = UserDefaults.standard

    static var providerID: ProviderID {
        get { defaults.string(forKey: "providerID").flatMap(ProviderID.init(rawValue:)) ?? .ollama }
        set { defaults.set(newValue.rawValue, forKey: "providerID") }
    }

    static func model(for provider: ProviderID) -> String? {
        defaults.string(forKey: "model.\(provider.rawValue)")
    }

    static func setModel(_ model: String, for provider: ProviderID) {
        defaults.set(model, forKey: "model.\(provider.rawValue)")
    }

    static var speakReplies: Bool {
        get { defaults.object(forKey: "speakReplies") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "speakReplies") }
    }

    static var hasOnboarded: Bool {
        get { defaults.bool(forKey: "hasOnboarded") }
        set { defaults.set(newValue, forKey: "hasOnboarded") }
    }

    static var toolsEnabled: Bool {
        get { defaults.object(forKey: "toolsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "toolsEnabled") }
    }
}
