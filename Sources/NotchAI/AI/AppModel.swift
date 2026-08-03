import SwiftUI

/// Everything behind the notch that isn't the notch itself.
@MainActor
final class AppModel: ObservableObject {
    let chat = ChatModel()
    let transcriber = Transcriber()
    let speaker = Speaker()

    @Published var speakReplies: Bool = Settings.speakReplies {
        didSet { Settings.speakReplies = speakReplies }
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
        speaker.stop()
        await transcriber.stop()
        chat.cancel()
    }
}
