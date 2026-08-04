import SwiftUI

struct ChatPanel: View {
    // Each of these has to be observed in its own right. Observing only
    // `AppModel` and reaching through to `app.chat` silently drops every
    // update: the nested objects publish to their own `objectWillChange`,
    // which no view is subscribed to — so the panel only ever refreshed when
    // it was rebuilt from scratch on reopen.
    @ObservedObject var app: AppModel
    @ObservedObject var chat: ChatModel
    @ObservedObject var transcriber: Transcriber

    @State private var draft = ""
    @State private var apiKeyDraft = ""
    @State private var needsKey = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            transcript
            Divider().overlay(Color.white.opacity(0.08))
            if let call = chat.pendingApproval {
                approval(for: call)
            } else if needsKey {
                keyEntry
            } else {
                composer
            }
        }
        .padding(.top, 6)
        .onAppear {
            refreshKeyGate()
            inputFocused = true
        }
        .onChange(of: chat.providerID) { _, _ in refreshKeyGate() }
        .onChange(of: chat.isStreaming) { wasStreaming, isStreaming in
            // Speak only on the falling edge, once the full reply exists.
            if wasStreaming, !isStreaming { app.replyCompleted() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            menu(label: chat.providerID.displayName) {
                ForEach(ProviderID.allCases, id: \.self) { provider in
                    Button(provider.displayName) { chat.providerID = provider }
                }
            }

            menu(label: chat.model.isEmpty ? "model" : chat.model) {
                if chat.availableModels.isEmpty {
                    Text("Geen modellen gevonden")
                } else {
                    ForEach(chat.availableModels, id: \.self) { name in
                        Button(name) { chat.model = name }
                    }
                }
            }

            Spacer(minLength: 0)

            iconButton(app.speakReplies ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                app.speakReplies.toggle()
                if !app.speakReplies { app.speaker.stop() }
            }

            iconButton("arrow.counterclockwise") {
                chat.reset()
                app.speaker.stop()
            }

            iconButton("gearshape.fill") { app.route = .settings }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func menu<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if chat.messages.isEmpty && transcriber.transcript.isEmpty {
                        placeholder
                    }

                    ForEach(chat.messages) { message in
                        bubble(for: message).id(message.id)
                    }

                    // Between "sent" and the first token there is otherwise no
                    // sign the thing is alive — with a local model that gap can
                    // be a second or two, and a tool call much longer.
                    if let activity = chat.activity {
                        ThinkingIndicator(label: activity).id("activity")
                    }

                    // Live dictation sits below the conversation as a preview of
                    // what will be sent.
                    if transcriber.isRecording {
                        HStack(spacing: 6) {
                            Text(transcriber.transcript.isEmpty
                                 ? "Luisteren…"
                                 : transcriber.transcript)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.5))
                            // Dutch falls back to a different engine and English
                            // falls back further still; say which, or a wrong
                            // language looks like a bug.
                            if let locale = transcriber.activeLocale {
                                Text(locale.identifier)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                        }
                        .id("dictation")
                    }

                    if let error = chat.errorText ?? transcriber.errorText {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange.opacity(0.9))
                            .id("error")
                    }

                    // Anchoring to the last *message* left the activity
                    // indicator, the live dictation and any error below the
                    // fold — the very things you want to see. A zero-height
                    // anchor after everything always lands at the true bottom.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: chat.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: chat.messages.last?.text) { _, _ in scrollToBottom(proxy) }
            .onChange(of: chat.activity) { _, _ in scrollToBottom(proxy) }
            .onChange(of: transcriber.transcript) { _, _ in scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy, animated: false) }
        }
    }

    /// Streaming appends a few characters at a time, so this fires often;
    /// keep it cheap and let SwiftUI coalesce.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard animated else {
            proxy.scrollTo("bottom", anchor: .bottom)
            return
        }
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Spreek of typ")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text(chat.providerID.isLocal
                 ? "Draait lokaal — er verlaat niets je Mac."
                 : "Gaat naar \(chat.providerID.displayName).")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    @ViewBuilder
    private func bubble(for message: ChatMessage) -> some View {
        switch message.role {
        case .tool:
            // The raw output is context for the model, not for the reader —
            // show that it happened and let the summary speak.
            toolRow(icon: "checkmark.circle", label: message.toolName ?? "tool", detail: message.text)

        case .system:
            EmptyView()

        default:
            VStack(alignment: .leading, spacing: 6) {
                if !message.text.isEmpty {
                    HStack {
                        if message.role == .user { Spacer(minLength: 40) }
                        Text(message.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(message.role == .user ? 0.95 : 0.82))
                            .textSelection(.enabled)
                            .padding(.horizontal, message.role == .user ? 10 : 0)
                            .padding(.vertical, message.role == .user ? 6 : 0)
                            .background {
                                if message.role == .user {
                                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1))
                                }
                            }
                        if message.role == .assistant { Spacer(minLength: 40) }
                    }
                }
                ForEach(message.toolCalls) { call in
                    toolRow(icon: "wrench.and.screwdriver", label: call.summary, detail: nil)
                }
            }
        }
    }

    private func toolRow(icon: String, label: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.28))
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Approval

    private func approval(for call: ToolCall) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.9))
                Text("Wil je dit uitvoeren?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }

            // The exact call, verbatim: approving something you can't read is
            // not consent.
            Text(call.summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))

            HStack(spacing: 8) {
                Spacer()
                Button("Weiger") { chat.resolveApproval(allow: false) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                Button("Uitvoeren") { chat.resolveApproval(allow: true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.8)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    if transcriber.isRecording {
                        await app.finishDictation()
                    } else {
                        app.speaker.stop()
                        await transcriber.start()
                    }
                }
            } label: {
                Image(systemName: transcriber.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(transcriber.isRecording ? .red : .white.opacity(0.65))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)

            TextField("Vraag iets…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($inputFocused)
                .onSubmit(send)

            Button(action: chat.isStreaming ? chat.cancel : send) {
                Image(systemName: chat.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(canSend || chat.isStreaming ? 0.85 : 0.25))
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !chat.isStreaming)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        app.speaker.stop()
        chat.send(draft)
        draft = ""
    }

    // MARK: - API key

    private var keyEntry: some View {
        HStack(spacing: 10) {
            SecureField("API-key voor \(chat.providerID.displayName)", text: $apiKeyDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .onSubmit(saveKey)

            Button("Bewaar", action: saveKey)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(apiKeyDraft.isEmpty ? 0.25 : 0.85))
                .disabled(apiKeyDraft.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func saveKey() {
        guard KeychainStore.setAPIKey(apiKeyDraft, for: chat.providerID) else { return }
        apiKeyDraft = ""
        refreshKeyGate()
        Task { await chat.refreshModels() }
    }

    private func refreshKeyGate() {
        needsKey = !chat.providerID.isLocal && !KeychainStore.hasAPIKey(for: chat.providerID)
    }
}
