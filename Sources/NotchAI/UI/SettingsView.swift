import AppKit
import SwiftUI

/// Everything configurable, inside the notch.
struct SettingsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var chat: ChatModel
    @ObservedObject var ollama: OllamaSetup

    @State private var keyDrafts: [ProviderID: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Instellingen",
                        onBack: { app.route = .chat },
                        onClose: nil)
            Divider().overlay(Panel.hairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modelSection
                    behaviourSection
                    keysSection
                    localSection
                    ModelCatalogView(chat: chat, ollama: ollama)
                    permissionsSection
                    aboutSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .task { await ollama.refresh() }
    }

    // MARK: - Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            GroupHead(text: "Model")

            SettingRow(title: "Provider",
                       subtitle: chat.providerID.isLocal
                           ? "Draait lokaal, geen data verstuurd"
                           : "Verstuurt je gesprek naar \(chat.providerID.displayName)") {
                Picker("", selection: $chat.providerID) {
                    ForEach(ProviderID.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 130)
            }

            Divider().overlay(Panel.hairline)

            SettingRow(title: "Model",
                       subtitle: chat.availableModels.isEmpty
                           ? "Geen modellen gevonden — key ingesteld?"
                           : "\(chat.availableModels.count) beschikbaar") {
                if chat.availableModels.isEmpty {
                    Button("Verversen") { Task { await chat.refreshModels() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Panel.inkSoft)
                } else {
                    Picker("", selection: $chat.model) {
                        ForEach(chat.availableModels, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170)
                }
            }
        }
    }

    // MARK: - Behaviour

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            GroupHead(text: "Gedrag")

            SettingRow(title: "Tools",
                       subtitle: "Laat het model je mail, agenda, bestanden en taken bereiken") {
                PanelToggle(isOn: $chat.toolsEnabled)
            }
            Divider().overlay(Panel.hairline)
            Divider().overlay(Panel.hairline)
            SettingRow(title: "Specialisten",
                       subtitle: chat.orchestrationEnabled
                           ? "De orchestrator ziet zes domeinen en delegeert"
                           : "Alle \(ToolRegistry.shared.tools.count) tools direct aan één model") {
                PanelToggle(isOn: $chat.orchestrationEnabled)
            }
            if chat.orchestrationEnabled {
                Divider().overlay(Panel.hairline)
                SettingRow(title: "Model voor specialisten",
                           subtitle: "Kleiner en sneller; ze hebben een smal domein") {
                    Picker("", selection: Binding(
                        get: { Settings.specialistModel ?? chat.model },
                        set: { Settings.specialistModel = $0 == chat.model ? nil : $0 }
                    )) {
                        ForEach(chat.availableModels, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    .disabled(chat.availableModels.isEmpty)
                }
            }
            Divider().overlay(Panel.hairline)
            SettingRow(title: "Zwevende pill",
                       subtitle: "In plaats van in de notch. Vereist herstart.") {
                PanelToggle(isOn: Binding(
                    get: { Settings.preferPill },
                    set: { Settings.preferPill = $0 }))
            }
            Divider().overlay(Panel.hairline)
            SettingRow(title: "Antwoord voorlezen",
                       subtitle: "Spreekt het antwoord uit zodra het klaar is") {
                PanelToggle(isOn: $app.speakReplies)
            }
        }
    }

    // MARK: - Keys

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupHead(text: "API-sleutels")
            Text("Opgeslagen in de Keychain van macOS, nooit in een instellingenbestand.")
                .font(.system(size: 10.5))
                .foregroundStyle(Panel.inkFaint)

            ForEach(ProviderID.allCases.filter { !$0.isLocal }, id: \.self) { provider in
                APIKeyField(provider: provider,
                            draft: Binding(get: { keyDrafts[provider] ?? "" },
                                           set: { keyDrafts[provider] = $0 }))
            }
        }
    }

    // MARK: - Local stack

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupHead(text: "Lokaal")

            switch ollama.step {
            case .checking:
                Text("Ollama controleren…").font(.system(size: 12)).foregroundStyle(Panel.inkSoft)
            case .notInstalled:
                SettingRow(title: "Ollama", subtitle: "Niet geïnstalleerd") {
                    PanelButton(title: "Downloaden", prominent: false) { ollama.openDownloadPage() }
                }
            case .installedNotRunning:
                SettingRow(title: "Ollama", subtitle: "Geïnstalleerd, draait niet") {
                    PanelButton(title: "Starten", prominent: false) {
                        Task { await ollama.launchOllama() }
                    }
                }
            case .runningNoModel:
                SettingRow(title: "Ollama", subtitle: "Draait, geen model") {
                    PanelButton(title: "Model halen", prominent: false) { Task { await ollama.pull() } }
                }
            case let .ready(models):
                SettingRow(title: "Ollama", subtitle: "\(models.count) model(len) lokaal") {
                    if ollama.isPulling {
                        Text("\(Int((ollama.pullProgress ?? 0) * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Panel.inkFaint)
                    } else {
                        PanelButton(title: "Update model", prominent: false) {
                            Task { await ollama.pull() }
                        }
                    }
                }
            }

            if ollama.isPulling {
                ProgressView(value: ollama.pullProgress ?? 0)
                    .progressViewStyle(.linear)
                    .tint(.white.opacity(0.85))
            }
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            GroupHead(text: "Toegang")

            SettingRow(title: "Volledige schijftoegang",
                       subtitle: mailReadable
                           ? "Mail kan gelezen worden"
                           : "Nodig om je mail te kunnen lezen") {
                if mailReadable {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green.opacity(0.85))
                } else {
                    PanelButton(title: "Openen", prominent: false) {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
            }
            if !mailReadable {
                Text("Zet NotchAI aan in de lijst en start de app opnieuw.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Panel.inkFaint)
            }
        }
    }

    private var mailReadable: Bool {
        if case .found = ListMailTool.locateIndex() { return true }
        return false
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            GroupHead(text: "Over")

            SettingRow(title: "Xinori Notch AI",
                       subtitle: "Versie \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") · MIT") {
                Button("GitHub") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/sicparvisventures/xinori-notch-ai")!)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Panel.inkSoft)
            }
            Divider().overlay(Panel.hairline)
            SettingRow(title: "Setup opnieuw doorlopen",
                       subtitle: "Toont de installatiestappen weer") {
                PanelButton(title: "Start", prominent: false) { app.restartOnboarding() }
            }
        }
    }
}
