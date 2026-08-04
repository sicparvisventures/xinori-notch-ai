import SwiftUI

/// Per-source control over the index.
///
/// Every row is a decision the user makes, not a default they discover later.
/// The counts are there so "how much of my life is in this" has a number rather
/// than a feeling, and the wipe button is deliberately not hidden behind a
/// confirmation-of-a-confirmation.
struct MemorySettingsView: View {
    @ObservedObject var memory: MemoryIndexer
    @ObservedObject var ollama: OllamaSetup

    @State private var confirmingWipe = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupHead(text: "Geheugen")
            Text("""
            Alles blijft in één bestand op deze Mac en gaat nooit naar een server. \
            Zet per bron aan wat doorzocht mag worden.
            """)
            .font(.system(size: 10.5))
            .foregroundStyle(Panel.inkFaint)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(MemorySource.allCases) { source in
                row(for: source)
                if source != MemorySource.allCases.last {
                    Divider().overlay(Panel.hairline)
                }
            }

            Divider().overlay(Panel.hairline)
            semanticRow

            if let progress = memory.progressText {
                Text(progress)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Panel.inkFaint)
            }
            if let error = memory.errorText {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if confirmingWipe {
                    Text("Zeker weten?")
                        .font(.system(size: 11))
                        .foregroundStyle(Panel.inkSoft)
                    Button("Annuleer") { confirmingWipe = false }
                        .buttonStyle(.plain).font(.system(size: 11))
                        .foregroundStyle(Panel.inkFaint)
                    Button("Wis alles") {
                        Task {
                            try? await MemoryStore.shared.wipe(nil)
                            await memory.refreshCounts()
                            confirmingWipe = false
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.9))
                } else {
                    Button("Geheugen wissen") { confirmingWipe = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Panel.inkFaint)
                }
            }
        }
        .task { await memory.refreshCounts() }
    }

    private func row(for source: MemorySource) -> some View {
        let count = memory.counts[source] ?? 0
        let on = memory.enabled.contains(source)

        return SettingRow(
            title: source.displayName,
            subtitle: count > 0 ? "\(count) geïndexeerd · \(source.blurb)" : source.blurb
        ) {
            HStack(spacing: 8) {
                // Crawled sources need a button; the other two fill themselves
                // as you use the app, so offering "index now" would be a lie.
                if on, source == .notes || source == .mail {
                    if memory.busy == source {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        PanelButton(title: count > 0 ? "Bijwerken" : "Indexeer",
                                    prominent: false, enabled: memory.busy == nil) {
                            Task { await memory.reindex(source) }
                        }
                    }
                }
                PanelToggle(isOn: Binding(
                    get: { memory.enabled.contains(source) },
                    set: { isOn in
                        if isOn { memory.enabled.insert(source) }
                        else { memory.enabled.remove(source) }
                    }))
            }
        }
    }

    private var semanticRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(title: "Zoeken op betekenis",
                       subtitle: memory.embedded > 0
                           ? "\(memory.embedded) documenten ingebed"
                           : "Vindt ook wat je anders verwoordt dan je het opschreef") {
                HStack(spacing: 8) {
                    if memory.semanticEnabled, memory.busy == .facts {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else if memory.semanticEnabled, hasEmbeddingModel {
                        PanelButton(title: "Inbedden", prominent: false,
                                    enabled: memory.busy == nil) {
                            Task { await memory.buildEmbeddings() }
                        }
                    }
                    PanelToggle(isOn: $memory.semanticEnabled)
                }
            }

            if memory.semanticEnabled, !hasEmbeddingModel {
                // A chat model cannot stand in here: Ollama starts a server per
                // model and only enables embeddings for embedding models —
                // asking qwen3 returns "this server does not support embeddings".
                HStack(spacing: 8) {
                    Text("Vraagt het model \(MemoryIndexer.embeddingModel) (0,6 GB, meertalig).")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Panel.inkFaint)
                    PanelButton(title: "Ophalen", prominent: false,
                                enabled: !ollama.isPulling) {
                        Task { await ollama.pull(MemoryIndexer.embeddingModel) }
                    }
                }
            }
        }
    }

    private var hasEmbeddingModel: Bool {
        ollama.isInstalled(MemoryIndexer.embeddingModel)
    }
}
