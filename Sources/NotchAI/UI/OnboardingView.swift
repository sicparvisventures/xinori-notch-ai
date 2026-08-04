import AppKit
import Contacts
import EventKit
import SwiftUI

/// First-run setup, inside the notch.
///
/// The goal is that someone who downloaded the app and has never heard of
/// Ollama ends up with a working local model without opening a terminal. Every
/// step reports live state rather than telling the user to go and verify
/// something themselves.
struct OnboardingView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var ollama: OllamaSetup
    @ObservedObject var chat: ChatModel

    @State private var step = 0
    @State private var keyDrafts: [ProviderID: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(
                title: titles[step],
                onBack: step > 0 ? { step -= 1 } : nil,
                onClose: nil
            )
            Divider().overlay(Panel.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch step {
                    case 0: welcome
                    case 1: localModel
                    case 2: access
                    default: providers
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }

            Divider().overlay(Panel.hairline)
            footer
        }
        .task { await ollama.refresh() }
    }

    private let titles = ["Welkom", "Lokaal model", "Toegang", "Cloud-providers"]

    // MARK: - Step 0

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Je Mac beantwoordt nu je vragen.")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Panel.ink)

            Text("""
            Klik op de notch en vraag wat je wil weten. Xinori Notch AI leest je mail, \
            checkt je agenda, vindt bestanden terug en plant taken in.
            """)
            .font(.system(size: 12.5))
            .foregroundStyle(Panel.inkSoft)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                bullet("lock.fill", "Standaard lokaal",
                       "Het model draait op je eigen Mac. Je data verlaat je machine niet.")
                bullet("hand.raised.fill", "Vraagt voordat het iets verandert",
                       "Lezen mag vrij. Aanpassen of uitvoeren pas na jouw goedkeuring.")
                bullet("mic.fill", "Praat of typ",
                       "Spraak wordt op het toestel zelf omgezet naar tekst.")
            }
            .padding(.top, 2)
        }
    }

    private func bullet(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Panel.inkFaint)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Panel.ink.opacity(0.9))
                Text(body).font(.system(size: 11)).foregroundStyle(Panel.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Step 1

    private var localModel: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupHead(text: "Stap 1 — Ollama")

            switch ollama.step {
            case .checking:
                status("hourglass", "Even kijken wat er al staat…", tone: .neutral)

            case .notInstalled:
                status("arrow.down.circle", "Ollama is nog niet geïnstalleerd.", tone: .neutral)
                Text("""
                Ollama draait het taalmodel lokaal op je Mac. Gratis, en het is de reden \
                dat je gegevens je machine niet verlaten.
                """)
                .font(.system(size: 11.5)).foregroundStyle(Panel.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PanelButton(title: "Download Ollama", icon: "arrow.up.right.square") {
                        ollama.openDownloadPage()
                    }
                    PanelButton(title: "Ik heb het geïnstalleerd", prominent: false) {
                        Task { await ollama.refresh() }
                    }
                }

            case .installedNotRunning:
                status("play.circle", "Ollama staat er, maar draait nog niet.", tone: .neutral)
                PanelButton(title: "Ollama starten", icon: "play.fill") {
                    Task { await ollama.launchOllama() }
                }

            case .runningNoModel:
                status("square.and.arrow.down", "Ollama draait. Nu nog een model.", tone: .neutral)
                modelPull

            case let .ready(models):
                if models.contains(where: { $0.hasPrefix("qwen3") }) {
                    status("checkmark.circle.fill", "Klaar — \(models.first(where: { $0.hasPrefix("qwen3") })!) staat lokaal.", tone: .good)
                } else {
                    status("checkmark.circle", "Ollama draait met \(models.count) model(len).", tone: .good)
                    Text("We raden \(OllamaSetup.defaultModel) aan: die kan tools aanroepen, wat de meeste modellen niet kunnen.")
                        .font(.system(size: 11.5)).foregroundStyle(Panel.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    modelPull
                }
            }

            if let error = ollama.errorText {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelPull: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ollama.isPulling {
                VStack(alignment: .leading, spacing: 5) {
                    // A 5 GB download with no bar feels broken; the byte
                    // counters from Ollama make a real one possible.
                    ProgressView(value: ollama.pullProgress ?? 0)
                        .progressViewStyle(.linear)
                        .tint(.white.opacity(0.85))
                    Text("\(ollama.pullStatus ?? "Bezig") · \(Int((ollama.pullProgress ?? 0) * 100))%")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Panel.inkFaint)
                }
            } else {
                PanelButton(title: "Download \(OllamaSetup.defaultModel) (5,2 GB)", icon: "arrow.down") {
                    Task { await ollama.pull() }
                }
            }
        }
    }

    private enum Tone { case neutral, good }

    private func status(_ icon: String, _ text: String, tone: Tone) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tone == .good ? Color.green.opacity(0.85) : Panel.inkSoft)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Panel.ink.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 2 — access, one grant at a time

    /// Asked per capability rather than as one block.
    ///
    /// A single "grant everything" step reads as a demand and gets refused
    /// wholesale; naming what each grant buys lets someone take the calendar and
    /// skip the mail, which is a perfectly reasonable thing to want.
    private var access: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupHead(text: "Wat mag het zien")
            Text("""
            macOS vraagt dit per onderdeel. Je hoeft niets nu te doen — de app vraagt \
            het ook op het moment dat het nodig is.
            """)
            .font(.system(size: 11.5)).foregroundStyle(Panel.inkFaint)
            .fixedSize(horizontal: false, vertical: true)

            grant("Microfoon en spraak", "Om te kunnen dicteren. Spraak blijft op het toestel.",
                  action: "Vraag nu") {
                Task { _ = await Transcriber.requestAuthorization() }
            }
            grant("Agenda en herinneringen", "Om te kunnen zeggen wat er op de planning staat.",
                  action: "Vraag nu") {
                Task { _ = try? await EKEventStore().requestFullAccessToEvents() }
            }
            grant("Contacten", "Om een nummer of adres te kunnen opzoeken.",
                  action: "Vraag nu") {
                Task { _ = try? await CNContactStore().requestAccess(for: .contacts) }
            }
            grant("Volledige schijftoegang", "Alleen nodig voor mail en notities. macOS laat dit niet vragen — je zet het zelf aan.",
                  action: "Open paneel") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            }
        }
    }

    private func grant(_ title: String, _ why: String,
                       action: String, run: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Panel.ink.opacity(0.9))
                Text(why)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Panel.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            PanelButton(title: action, prominent: false, action: run)
        }
    }

    // MARK: - Step 3

    private var providers: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupHead(text: "Optioneel")
            Text("""
            Wil je later een krachtiger cloud-model kunnen kiezen, plak dan hier je sleutel. \
            Die gaat in de Keychain van macOS en kan altijd nog via instellingen.
            """)
            .font(.system(size: 11.5)).foregroundStyle(Panel.inkFaint)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(ProviderID.allCases.filter { !$0.isLocal }, id: \.self) { provider in
                APIKeyField(provider: provider, draft: binding(for: provider))
            }
        }
    }

    private func binding(for provider: ProviderID) -> Binding<String> {
        Binding(get: { keyDrafts[provider] ?? "" },
                set: { keyDrafts[provider] = $0 })
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if step == 2 {
                Text("Elk onderdeel is los te weigeren.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Panel.inkFaint)
            }
            if step == 1, !ollama.step.isReady {
                Text("Je kunt dit overslaan en later in instellingen afmaken.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Panel.inkFaint)
            }
            Spacer(minLength: 0)

            if step < 3 {
                if step == 1 || step == 2 {
                    Button("Overslaan") { step += 1 }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Panel.inkSoft)
                }
                PanelButton(title: step == 0 ? "Aan de slag" : "Verder", icon: "chevron.right") {
                    step += 1
                }
            } else {
                PanelButton(title: "Klaar", icon: "checkmark") {
                    app.finishOnboarding()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Key entry with a saved/unsaved state, shared by onboarding and settings.
struct APIKeyField: View {
    let provider: ProviderID
    @Binding var draft: String
    @State private var stored = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Panel.ink.opacity(0.9))
                if stored {
                    Text("opgeslagen")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.green.opacity(0.85))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.green.opacity(0.14)))
                }
                Spacer(minLength: 0)
                if stored {
                    Button("Verwijder") {
                        KeychainStore.removeAPIKey(for: provider)
                        stored = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Panel.inkFaint)
                }
            }

            HStack(spacing: 6) {
                SecureField(stored ? "••••••••••••" : "Plak je API-key", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Panel.ink)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Panel.surface))
                    .onSubmit(save)

                PanelButton(title: "Bewaar", prominent: false, enabled: !draft.isEmpty, action: save)
            }
        }
        .onAppear { stored = KeychainStore.hasAPIKey(for: provider) }
    }

    private func save() {
        guard !draft.isEmpty, KeychainStore.setAPIKey(draft, for: provider) else { return }
        draft = ""
        stored = true
    }
}
