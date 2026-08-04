import Foundation

/// Search across everything indexed, in one place.
///
/// Word search and meaning search answer different questions: FTS5 finds
/// "Van Damme" and misses "die aannemer uit Gent"; the vector path does the
/// reverse. Running both and merging costs one extra query and removes the need
/// for the user to know which kind of question they just asked.
struct SearchMemoryTool: Tool {
    let activityLabel = "Zoekt in je geheugen"
    let name = "search_memory"
    let description = """
    Doorzoekt alles wat geïndexeerd is: notities, mailonderwerpen, eerdere gesprekken \
    en onthouden feiten. Gebruik dit voor 'wat weet ik over X', 'wat hebben we hierover \
    afgesproken' of wanneer je context mist over een naam, project of klant.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = """
    {"type":"object","properties":{
      "query":{"type":"string","description":"Waar je naar zoekt."},
      "limit":{"type":"integer","description":"Maximaal aantal resultaten, standaard 6."}},
     "required":["query"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let query = try arguments.requiredString("query")
        let limit = min(arguments.int("limit", default: 6), 20)

        let sources = await MainActor.run { Settings.memorySources }
        guard !sources.isEmpty else {
            throw ToolError.unavailable(
                "Het geheugen is nog leeg. Zet in instellingen aan welke bronnen geïndexeerd mogen worden.")
        }

        let store = MemoryStore.shared
        var hits = (try? await store.search(query, sources: sources, limit: limit)) ?? []

        // Meaning search only adds value when there are vectors to compare
        // against; a fresh index has none, so this quietly does nothing then.
        let semantic = await MainActor.run { Settings.semanticMemory }
        if semantic {
            if let vector = try? await Self.embed(query),
               let semantic = try? await store.semanticSearch(vector, sources: sources, limit: limit) {
                let known = Set(hits.map(\.id))
                hits += semantic.filter { !known.contains($0.id) && $0.score > 0.55 }
            }
        }

        guard !hits.isEmpty else {
            return "Niets gevonden over '\(query)' in je geheugen."
        }

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "d MMM yyyy"

        let lines = hits.prefix(limit).map { hit -> String in
            let snippet = hit.snippet
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return "[\(hit.source.displayName), \(formatter.string(from: hit.modified))] "
                + "\(hit.title) — \(snippet.prefix(160))"
        }
        return "\(hits.count) treffers voor '\(query)':\n" + lines.joined(separator: "\n")
    }

    private static func embed(_ text: String) async throws -> [Float] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/embed")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": MemoryIndexer.embeddingModel,
            "input": [text],
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Reply: Decodable { let embeddings: [[Float]]? }
        guard let vector = try JSONDecoder().decode(Reply.self, from: data).embeddings?.first else {
            throw MemoryError.query("geen embedding")
        }
        return vector
    }
}

/// The one thing the index cannot derive from existing sources: what you told
/// it directly.
///
/// Mutating on purpose. Something that quietly writes down what you say, with
/// no prompt and no visible record, is a different product from one that asks.
struct RememberTool: Tool {
    let activityLabel = "Onthoudt iets"
    let name = "remember"
    let description = """
    Onthoudt een feit voor later, bijvoorbeeld een voorkeur, een afspraak over hoe iets \
    moet, of context over een klant of project. Gebruik dit als de gebruiker zegt \
    'onthou dat…' of iets vertelt dat later opnieuw van pas komt. Houd het kort en \
    op zichzelf staand — het wordt maanden later teruggevonden zonder dit gesprek.
    """
    let risk = ToolRisk.mutating
    let parametersJSON = """
    {"type":"object","properties":{
      "subject":{"type":"string","description":"Waar het over gaat, in twee of drie woorden. Dient als sleutel."},
      "fact":{"type":"string","description":"Het feit zelf, in één of twee zinnen."}},
     "required":["subject","fact"]}
    """

    func run(arguments: [String: Any]) async throws -> String {
        let subject = try arguments.requiredString("subject")
        let fact = try arguments.requiredString("fact")

        _ = try await MemoryStore.shared.upsert(MemoryDocument(
            source: .facts, ref: subject.lowercased(),
            title: subject, body: fact, modified: Date()))

        return "Onthouden onder '\(subject)': \(fact)"
    }
}

/// Everything the index knows, so "what do you remember about me" has an
/// answer that isn't a guess.
struct MemoryStatusTool: Tool {
    let activityLabel = "Bekijkt je geheugen"
    let name = "memory_status"
    let description = """
    Geeft hoeveel er per bron in het geheugen zit. Gebruik dit als de gebruiker vraagt \
    wat je over hem weet of hoe groot het geheugen is.
    """
    let risk = ToolRisk.readOnly
    let parametersJSON = #"{"type":"object","properties":{}}"#

    func run(arguments: [String: Any]) async throws -> String {
        let counts = await MemoryStore.shared.counts()
        let embedded = await MemoryStore.shared.embeddedCount()
        guard !counts.isEmpty else {
            return "Het geheugen is leeg. In instellingen kun je per bron aanzetten wat geïndexeerd mag worden."
        }
        let lines = counts.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.displayName): \($0.value)" }
        return "Geheugen:\n" + lines.joined(separator: "\n")
            + "\n\(embedded) daarvan zijn ook semantisch doorzoekbaar."
    }
}
