import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchWindowController?
    private var menuBar: MenuBarController?
    private var app: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let placement = Placement.current() else {
            Log.write("no usable screen found — nothing to attach to.")
            NSApp.terminate(nil)
            return
        }
        Log.write(placement.describedForLog)

        let notch = NotchModel(placement: placement)
        let app = AppModel()
        let controller = NotchWindowController(model: notch, app: app)
        controller.show()

        // The menu bar is the app's only handle when the panel misbehaves —
        // and the only way to quit without reaching for Terminal.
        self.menuBar = MenuBarController(app: app, notch: notch)
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
        if !chat.trace.isEmpty {
            print("--- trace ---")
            for step in chat.trace {
                print("  \(step.label): \(step.detail) [\(step.durationText)]")
            }
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
