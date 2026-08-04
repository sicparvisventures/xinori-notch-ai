import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchWindowController?
    private var menuBar: MenuBarController?
    private var hotKey: HotKey?
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
        // ⌥Space: faster than aiming at 185 × 32 points.
        self.hotKey = HotKey { notch.toggle() }
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

/// `NotchAI --memory-selftest` writes, indexes, searches and embeds a handful of
/// documents, then reports. The store is the one part with no visible surface of
/// its own, so it needs a way to be exercised without clicking through the UI.
if CommandLine.arguments.contains("--memory-selftest") {
    Task { @MainActor in
        let store = MemoryStore.shared
        let indexer = MemoryIndexer()

        let samples = [
            ("Van Damme", "Aannemer uit Gent, werkt aan de verbouwing van het magazijn."),
            ("Kwartaalaangifte", "Btw-aangifte moet voor de 20e, cijfers naar de boekhouder."),
            ("Koffie", "De espressomachine op kantoor moet elke maandag ontkalkt worden."),
        ]
        for (subject, fact) in samples {
            _ = try? await store.upsert(MemoryDocument(
                source: .facts, ref: subject.lowercased(),
                title: subject, body: fact, modified: Date()))
        }
        print("geschreven: \(samples.count) feiten")

        let counts = await store.counts()
        print("index: " + counts.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "))

        for query in ["aangifte", "magazijn"] {
            let hits = (try? await store.search(query, sources: [.facts], limit: 3)) ?? []
            print("woordzoek '\(query)': " + (hits.isEmpty ? "niets"
                : hits.map { "\($0.title)" }.joined(separator: ", ")))
        }

        // The interesting case: wording that shares no word with the document.
        if (try? await indexer.embed(["test"])) != nil {
            await indexer.buildEmbeddings()
            if let vector = try? await indexer.embed(["die bouwvakker uit Oost-Vlaanderen"], as: .query).first,
               let hits = try? await store.semanticSearch(vector, sources: [.facts], limit: 3) {
                print("betekeniszoek 'die bouwvakker uit Oost-Vlaanderen':")
                for hit in hits {
                    print(String(format: "   %.3f  %@", hit.score, hit.title))
                }
            }
        } else {
            print("betekeniszoek: overgeslagen — geen embedding-model")
        }

        try? await store.wipe(.facts)
        print("opgeruimd")
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
