import SwiftUI

/// Everything behind the notch that isn't the notch itself.
@MainActor
final class AppModel: ObservableObject {
    /// What the open panel is showing. Settings and onboarding live *inside*
    /// the notch rather than in a separate window — a floating preferences
    /// window would break the illusion that this is part of the hardware.
    enum Route: Equatable {
        case onboarding
        case chat
        case settings
    }

    let chat = ChatModel()
    let transcriber = Transcriber()
    let speaker = Speaker()
    let ollama = OllamaSetup()
    let memory = MemoryIndexer()

    @Published var route: Route

    @Published var speakReplies: Bool = Settings.speakReplies {
        didSet { Settings.speakReplies = speakReplies }
    }

    init() {
        route = Settings.hasOnboarded ? .chat : .onboarding
    }

    func finishOnboarding() {
        Settings.hasOnboarded = true
        route = .chat
        Task { await chat.refreshModels() }
    }

    func restartOnboarding() {
        Settings.hasOnboarded = false
        route = .onboarding
    }

    /// Stop listening and hand whatever was heard to the model.
    func finishDictation() async {
        await transcriber.stop()
        let text = transcriber.transcript
        guard !text.isEmpty else { return }
        chat.send(text)
    }

    /// Called when a reply finishes streaming.
    func replyCompleted() {
        guard speakReplies, let text = chat.lastAssistantText else { return }
        speaker.speak(text)
    }

    /// Closing the notch should never leave audio running behind it.
    func standDown() async {
        // A finished conversation is worth keeping if the user opted in — it is
        // the only source that records what the assistant already told them.
        await memory.remember(conversation: chat.messages)
        speaker.stop()
        await transcriber.stop()
        chat.cancel()
        // Settings is a detour, not a place to be left; onboarding is not
        // finished until it says so.
        if route == .settings { route = .chat }
    }
}
