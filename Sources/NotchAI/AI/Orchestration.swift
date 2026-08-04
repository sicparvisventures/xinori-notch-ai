import Foundation

extension ChatModel {
    /// Run one specialist to completion and hand back a summary.
    ///
    /// A specialist gets the *task*, never the conversation: it costs fewer
    /// tokens and stops it meddling in work that isn't its own. What comes back
    /// is capped hard — the whole point of delegation is that 31k mail rows stay
    /// inside the specialist. Returning them to the orchestrator would just move
    /// the context problem one level up.
    func runSpecialist(_ domain: ToolDomain, task: String) async -> String {
        let step = beginStep(label: domain.displayName, detail: task)

        let provider = self.provider
        let model = modelTag(for: domain.tier)
        let schemas = domain.tools.map(\.schema)

        var history: [ChatMessage] = [
            ChatMessage(role: .system, text: domain.systemPrompt),
            ChatMessage(role: .user, text: task),
        ]
        var used: [String] = []
        // Kept as the fallback when the model's own summary is unusable.
        var lastOutput = ""

        for _ in 0..<domain.maxRounds {
            guard !Task.isCancelled else { break }

            var text = ""
            var calls: [ToolCall] = []
            do {
                for try await event in provider.stream(messages: history, model: model, tools: schemas) {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case let .text(delta): text += delta
                    case let .toolCall(call): calls.append(call)
                    }
                }
            } catch {
                finishStep(step, detail: error.localizedDescription, state: .failed)
                return "\(domain.displayName)-specialist faalde: \(error.localizedDescription)"
            }

            guard !calls.isEmpty else {
                finishStep(step, detail: used.isEmpty ? "geen tools" : used.joined(separator: ", "),
                           state: .done)
                return Self.report(text, lastToolOutput: lastOutput, domain: domain)
            }

            history.append(ChatMessage(role: .assistant, text: text, toolCalls: calls))
            for call in calls {
                used.append(call.name)
                updateStep(step, detail: used.joined(separator: ", "))
                // Risky tools inside a specialist hit exactly the same gate as
                // risky tools in the main loop — delegation must not become a
                // way around the approval prompt.
                let output = await execute(call)
                lastOutput = output
                history.append(ChatMessage(role: .tool, text: output,
                                           toolName: call.name, toolCallID: call.id))
            }
        }

        // Out of rounds: ask for the summary it never got round to writing.
        history.append(ChatMessage(
            role: .user,
            text: "Vat in twee zinnen samen wat je hebt gevonden of gedaan. Geen tools meer."))
        var closing = ""
        do {
            for try await event in provider.stream(messages: history, model: model, tools: []) {
                if case let .text(delta) = event { closing += delta }
            }
        } catch {
            // Nothing to add: the fallback text below already covers it.
        }
        finishStep(step, detail: used.joined(separator: ", "), state: .done)
        return Self.report(closing, lastToolOutput: lastOutput, domain: domain)
    }

    /// What actually goes back to the orchestrator.
    ///
    /// Small models with thinking disabled sometimes write their reasoning into
    /// the visible answer instead of the answer. Observed: the Shortcuts
    /// specialist returned "Okay, let me see. The user asked to list all
    /// available Shortcuts…" — and the orchestrator, given no facts, invented
    /// nine plausible shortcut names that did not exist. Passing the raw tool
    /// output instead of a narration about the tool output is strictly better
    /// than passing prose with no data in it.
    private static func report(_ summary: String, lastToolOutput: String,
                               domain: ToolDomain) -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !looksLikeReasoning(trimmed) {
            return cap(trimmed)
        }
        if !lastToolOutput.isEmpty {
            return cap(lastToolOutput)
        }
        return "\(domain.displayName)-specialist gaf geen bruikbaar antwoord."
    }

    /// Cheap heuristic, deliberately biased towards false positives: falling
    /// back to real tool output costs a few tokens, hallucinated names cost
    /// trust.
    private static func looksLikeReasoning(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let openers = ["okay", "ok,", "let me", "alright", "first,", "i need to",
                       "i should", "i called", "i'll ", "de gebruiker vroeg",
                       "de gebruiker wil", "laat me"]
        if openers.contains(where: { lowered.hasPrefix($0) }) { return true }
        let markers = ["the user asked", "the user wants", "i called the",
                       "wait,", "but the tool", "so i need"]
        return markers.contains(where: { lowered.contains($0) })
    }

    /// ~1500 characters. Longer than that means the specialist didn't summarise,
    /// and passing it on defeats the delegation.
    private static func cap(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1500 else { return trimmed }
        return String(trimmed.prefix(1500)) + "… (ingekort)"
    }

    /// The orchestrator's own prompt. The three speeds live here rather than in
    /// a separate classifier: one extra instruction is cheaper than an extra
    /// model call, and far easier to debug when it goes wrong.
    var orchestratorPrompt: String {
        let roster = ToolDomain.allCases
            .map { "- \($0.delegateName): \($0.summary)" }
            .joined(separator: "\n")

        return """
        Je bent de assistent in de notch van een MacBook. Je hebt specialisten die \
        elk een deel van deze Mac beheren.

        \(roster)

        Kies de kortste weg:
        1. Weet je het antwoord zelf, of gaat de vraag niet over deze Mac? Antwoord direct, \
           zonder specialist.
        2. Gaat het over één onderwerp? Roep één specialist aan.
        3. Alleen bij echt meerdere onderwerpen roep je er meerdere aan.

        Geef een specialist een volledige, op zichzelf staande opdracht — hij ziet dit \
        gesprek niet. Wacht het resultaat af en formuleer daarna zelf het antwoord voor \
        de gebruiker.

        Het venster is klein en antwoorden worden vaak voorgelezen: één tot drie zinnen, \
        geen markdown, geen opsommingen tenzij erom gevraagd wordt. Spreek de taal van \
        de gebruiker. Noem concrete namen, paden en datums uit wat de specialisten \
        terugmelden — nooit "ik kan dat opzoeken".
        """
    }

    func modelTag(for tier: ModelTier) -> String {
        switch tier {
        case .balanced:
            return model
        case .fast:
            // Fall back to the orchestrator's model when no faster one is set,
            // so delegation still works on a machine with a single model pulled.
            return Settings.specialistModel ?? model
        }
    }
}
