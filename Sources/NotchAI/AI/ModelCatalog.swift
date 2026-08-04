import Foundation

/// A curated set of local models, with the one fact that decides everything:
/// how much memory each one needs.
///
/// Sizes are the actual layer totals from the Ollama registry, not estimates —
/// a model that is advertised as "8B" can be anything from 4.5 to 9 GB on disk
/// depending on quantisation, and it's the bytes that have to fit in RAM.
struct CatalogModel: Identifiable, Sendable {
    var id: String { tag }

    let tag: String
    let name: String
    let bytes: UInt64
    let supportsTools: Bool
    let blurb: String

    var gigabytes: Double { Double(bytes) / 1_073_741_824 }

    /// How well this model sits on the current machine.
    enum Fit: Sendable {
        /// Runs with room to spare for everything else you have open.
        case comfortable
        /// Fits, but leaves little headroom — expect the fans.
        case tight
        /// Would swap. Listed so the choice is informed, never recommended.
        case tooLarge

        var label: String {
            switch self {
            case .comfortable: return "Past goed"
            case .tight: return "Krap"
            case .tooLarge: return "Te groot"
            }
        }
    }

    var fit: Fit {
        let budget = Hardware.memoryBudget
        if bytes <= UInt64(Double(budget) * 0.72) { return .comfortable }
        if bytes <= budget { return .tight }
        return .tooLarge
    }
}

enum ModelCatalog {
    /// Ordered small to large. Tool calling is not optional here — a model that
    /// can't call tools can't drive the Mac, which is the entire product — so
    /// non-tool models are simply absent rather than listed and warned about.
    static let all: [CatalogModel] = [
        CatalogModel(
            tag: "qwen3:4b", name: "Qwen3 4B", bytes: 2_500_000_000,
            supportsTools: true,
            blurb: "Snelst. Prima voor korte vragen en als specialist onder een orchestrator."),
        CatalogModel(
            tag: "qwen3:8b", name: "Qwen3 8B", bytes: 5_200_000_000,
            supportsTools: true,
            blurb: "De standaard. Goede balans tussen snelheid en oordeel bij tool-keuze."),
        CatalogModel(
            tag: "llama3.1:8b", name: "Llama 3.1 8B", bytes: 4_900_000_000,
            supportsTools: true,
            blurb: "Alternatief van vergelijkbare grootte; ander karakter in taal."),
        CatalogModel(
            tag: "mistral-nemo:12b", name: "Mistral Nemo 12B", bytes: 7_100_000_000,
            supportsTools: true,
            blurb: "Sterker in Europese talen, iets trager dan de 8B-modellen."),
        CatalogModel(
            tag: "qwen3:14b", name: "Qwen3 14B", bytes: 9_300_000_000,
            supportsTools: true,
            blurb: "Merkbaar beter in meerstaps redeneren. Vraagt een ruime Mac."),
        CatalogModel(
            tag: "gpt-oss:20b", name: "GPT-OSS 20B", bytes: 13_800_000_000,
            supportsTools: true,
            blurb: "Groot en capabel; alleen zinvol met veel geheugen."),
        CatalogModel(
            tag: "qwen3:30b-a3b", name: "Qwen3 30B (MoE)", bytes: 18_600_000_000,
            supportsTools: true,
            blurb: "Mixture-of-experts: rekent als een klein model, weegt als een groot."),
    ]

    /// The largest model that still sits comfortably. Not the largest that
    /// merely fits — the point of the recommendation is that you can keep
    /// working while it runs.
    static var recommended: CatalogModel? {
        all.last { $0.fit == .comfortable }
    }

    static func model(tagged tag: String) -> CatalogModel? {
        // Ollama reports `qwen3:8b` but also accepts bare `qwen3`; match loosely
        // so an already-pulled model is recognised as installed.
        all.first { $0.tag == tag || tag.hasPrefix($0.tag) || $0.tag.hasPrefix(tag) }
    }
}
