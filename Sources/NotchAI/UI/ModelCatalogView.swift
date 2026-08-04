import SwiftUI

/// Pick and download a local model, with the machine's own limits made visible.
///
/// The point of the fit badges is that "which model should I use" is not a taste
/// question on a laptop — it is a memory question with a right answer, and the
/// user shouldn't have to know model sizes to get it right.
struct ModelCatalogView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var ollama: OllamaSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupHead(text: "Lokale modellen")

            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 10))
                    .foregroundStyle(Panel.inkFaint)
                Text(Hardware.summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Panel.inkFaint)
                if let best = ModelCatalog.recommended {
                    Text("· aanbevolen: \(best.name)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.green.opacity(0.85))
                }
            }

            VStack(spacing: 0) {
                ForEach(ModelCatalog.all) { model in
                    row(for: model)
                    if model.id != ModelCatalog.all.last?.id {
                        Divider().overlay(Panel.hairline)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func row(for model: CatalogModel) -> some View {
        let installed = ollama.isInstalled(model.tag)
        let recommended = ModelCatalog.recommended?.tag == model.tag
        let selected = chat.model == model.tag
        let pulling = ollama.pullingTag == model.tag

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Panel.ink.opacity(selected ? 1 : 0.9))
                        if selected {
                            badge("in gebruik", .white.opacity(0.16), Panel.ink)
                        } else if recommended {
                            badge("aanbevolen", .green.opacity(0.16), .green.opacity(0.9))
                        }
                        fitBadge(model.fit)
                    }
                    Text(model.blurb)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Panel.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: "%.1f GB", model.gigabytes))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Panel.inkFaint.opacity(0.8))
                }

                Spacer(minLength: 6)

                if pulling {
                    Text("\(Int((ollama.pullProgress ?? 0) * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Panel.inkSoft)
                } else if installed {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.green.opacity(0.85))
                    } else {
                        PanelButton(title: "Gebruik", prominent: false) {
                            chat.model = model.tag
                        }
                    }
                } else {
                    PanelButton(title: "Download", prominent: false,
                                enabled: !ollama.isPulling) {
                        Task { await ollama.pull(model.tag) }
                    }
                }
            }

            if pulling {
                ProgressView(value: ollama.pullProgress ?? 0)
                    .progressViewStyle(.linear)
                    .tint(.white.opacity(0.85))
            }
        }
        .padding(.vertical, 8)
        .opacity(model.fit == .tooLarge && !installed ? 0.55 : 1)
    }

    private func badge(_ text: String, _ fill: Color, _ ink: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
    }

    @ViewBuilder
    private func fitBadge(_ fit: CatalogModel.Fit) -> some View {
        switch fit {
        case .comfortable:
            EmptyView()   // the default case needs no label
        case .tight:
            badge(fit.label, .orange.opacity(0.16), .orange.opacity(0.9))
        case .tooLarge:
            badge(fit.label, .white.opacity(0.10), Panel.inkFaint)
        }
    }
}
