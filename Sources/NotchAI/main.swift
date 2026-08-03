import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchWindowController?
    private var app: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let geometry = NotchGeometry.current() else {
            FileHandle.standardError.write(Data(
                "NotchAI: no notched built-in display found — nothing to attach to.\n".utf8))
            NSApp.terminate(nil)
            return
        }

        FileHandle.standardError.write(Data(
            "NotchAI: notch \(Int(geometry.size.width))×\(Int(geometry.size.height))pt at \(geometry.rect)\n".utf8))

        let notch = NotchModel(geometry: geometry)
        let app = AppModel()
        let controller = NotchWindowController(model: notch, app: app)
        controller.show()

        self.app = app
        self.controller = controller
    }
}

/// `NotchAI --check-permissions` requests microphone and speech access and
/// reports the outcome. TCC aborts the process outright when a usage string is
/// missing, so this is the cheapest way to tell a real denial apart from a
/// packaging mistake without having to click the mic button.
if CommandLine.arguments.contains("--check-permissions") {
    Task {
        let granted = await Transcriber.requestAuthorization()
        print(granted ? "permissions: granted" : "permissions: denied")
        exit(granted ? 0 : 1)
    }
    RunLoop.main.run()
}

/// `NotchAI --dictate` runs the speech pipeline headless for eight seconds and
/// prints what it heard. Exercising it without the UI is the only way to tell a
/// transcription problem apart from a panel or focus problem.
if CommandLine.arguments.contains("--dictate") {
    Task { @MainActor in
        let transcriber = Transcriber()
        await transcriber.start()
        guard transcriber.isRecording else {
            Log.write("dictation: failed to start — \(transcriber.errorText ?? "unknown")")
            exit(1)
        }
        Log.write("dictation: listening for 8s — say something")
        try? await Task.sleep(for: .seconds(8))
        await transcriber.stop()
        Log.write("dictation: heard \"\(transcriber.transcript)\"")
        exit(0)
    }
    RunLoop.main.run()
}

/// `NotchAI --ask "<vraag>"` runs one full turn — model, tools, results, answer —
/// and prints the transcript. Mutating tools are auto-denied here: a headless
/// run has nobody to approve them.
if let index = CommandLine.arguments.firstIndex(of: "--ask"),
   index + 1 < CommandLine.arguments.count {
    let question = CommandLine.arguments[index + 1]
    Task { @MainActor in
        let chat = ChatModel()
        await chat.refreshModels()
        Log.write("ask: \(chat.providerID.displayName)/\(chat.model), tools \(chat.toolsEnabled ? "on" : "off")")
        chat.send(question)

        let deadline = Date().addingTimeInterval(180)
        while chat.isStreaming, Date() < deadline {
            if let pending = chat.pendingApproval {
                Log.write("ask: auto-denying \(pending.summary)")
                chat.resolveApproval(allow: false)
            }
            try? await Task.sleep(for: .milliseconds(120))
        }

        for message in chat.messages where message.role != .system {
            let calls = message.toolCalls.map(\.summary).joined(separator: ", ")
            let suffix = calls.isEmpty ? "" : "  [\(calls)]"
            let body = message.text.replacingOccurrences(of: "\n", with: " ⏎ ")
            print("\(message.role.rawValue): \(body.prefix(400))\(suffix)")
        }
        if let error = chat.errorText { print("error: \(error)") }
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory: no Dock icon, no menu bar presence. The notch is the whole UI.
app.setActivationPolicy(.accessory)
app.run()
