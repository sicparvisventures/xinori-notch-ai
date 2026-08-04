import Foundation
import SwiftUI

/// Builds and maintains the index, one source at a time.
///
/// Every source is opt-in and counted, because an index that spans notes, mail
/// and past conversations is a more sensitive object than any of those on their
/// own. The user should be able to see exactly how much of their life is in
/// there and remove it in one action.
@MainActor
final class MemoryIndexer: ObservableObject {
    @Published private(set) var counts: [MemorySource: Int] = [:]
    @Published private(set) var embedded = 0
    @Published private(set) var busy: MemorySource?
    @Published private(set) var progressText: String?
    @Published private(set) var errorText: String?

    @Published var enabled: Set<MemorySource> {
        didSet { Settings.memorySources = enabled }
    }

    @Published var semanticEnabled: Bool {
        didSet { Settings.semanticMemory = semanticEnabled }
    }

    /// A dedicated, *multilingual* embedding model.
    ///
    /// Two constraints, both learned the hard way. A chat model cannot stand in:
    /// Ollama starts a server per model and only enables embeddings for
    /// embedding models — asking `qwen3` returns "This server does not support
    /// embeddings". And the obvious pick, `nomic-embed-text`, is effectively
    /// English-only. Measured on three Dutch facts, the query "die bouwvakker
    /// uit Oost-Vlaanderen" ranked the contractor from Ghent *last* (0.602,
    /// behind a note about descaling a coffee machine); the same three facts and
    /// query in English ranked it first at 0.713. `embeddinggemma` gets the
    /// Dutch case right (0.534 against 0.329 and 0.270) for 0.6 GB.
    static let embeddingModel = "embeddinggemma"

    private let store = MemoryStore.shared
    private let baseURL = URL(string: "http://127.0.0.1:11434")!

    init() {
        enabled = Settings.memorySources
        semanticEnabled = Settings.semanticMemory
    }

    func refreshCounts() async {
        counts = await store.counts()
        embedded = await store.embeddedCount()
    }

    // MARK: - Indexing

    func reindex(_ source: MemorySource) async {
        guard busy == nil else { return }
        busy = source
        errorText = nil
        defer { busy = nil; progressText = nil }

        do {
            switch source {
            case .notes: try await indexNotes()
            case .mail: try await indexMail()
            case .conversations, .facts:
                // Both are written as they happen; there is nothing to crawl.
                break
            }
            await refreshCounts()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func indexNotes() async throws {
        guard let path = NotesStore.path else { throw FullDiskAccess.error("je notities") }
        progressText = "Notities lezen…"

        // Empty query, high limit: the same reader the tool uses, in bulk mode.
        let result = try await Shell.capture(
            "/usr/bin/env", ["python3", "-c", NotesStore.reader, path, "", "5000", "1"],
            timeout: 240)
        guard result.status == 0 else {
            if FullDiskAccess.looksDenied(result.combined) { throw FullDiskAccess.error("je notities") }
            throw MemoryError.query(result.combined.prefix(160).description)
        }

        // The reader emits "title | date" then an indented body line.
        var indexed = 0
        var title = ""
        var when = Date()
        var body = ""

        func flush() async {
            guard !title.isEmpty else { return }
            _ = try? await store.upsert(MemoryDocument(
                source: .notes, ref: title, title: title, body: body, modified: when))
            indexed += 1
        }

        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("    ") {
                body += line.trimmingCharacters(in: .whitespaces) + " "
                continue
            }
            await flush()
            let parts = line.components(separatedBy: " | ")
            title = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            body = ""
            when = parts.count > 1
                ? (Self.dayFormatter.date(from: parts[1].trimmingCharacters(in: .whitespaces)) ?? Date())
                : Date()
            if indexed % 100 == 0 { progressText = "\(indexed) notities…" }
        }
        await flush()
        progressText = "\(indexed) notities geïndexeerd"
    }

    private func indexMail() async throws {
        guard case let .found(path) = ListMailTool.locateIndex() else {
            throw FullDiskAccess.error("je mail")
        }
        progressText = "Mail lezen…"

        // Senders and subjects only. Message bodies are both enormous and the
        // most sensitive thing on the machine; the subject line is what people
        // actually search for.
        let sql = """
        SELECT m.ROWID,
               COALESCE(NULLIF(a.comment,''), a.address, '?'),
               COALESCE(NULLIF(s.subject,''), '(geen onderwerp)'),
               m.date_received
        FROM messages m
        LEFT JOIN addresses a ON a.ROWID = m.sender
        LEFT JOIN subjects  s ON s.ROWID = m.subject
        WHERE m.deleted = 0
        ORDER BY m.date_received DESC LIMIT 4000;
        """
        let result = try await Shell.capture(
            "/usr/bin/sqlite3", ["-separator", "\u{1}", "file:\(path)?immutable=1", sql], timeout: 120)
        guard result.status == 0 else {
            if FullDiskAccess.looksDenied(result.combined) { throw FullDiskAccess.error("je mail") }
            throw MemoryError.query(result.combined.prefix(160).description)
        }

        var indexed = 0
        for line in result.stdout.split(separator: "\n") {
            let parts = line.components(separatedBy: "\u{1}")
            guard parts.count == 4 else { continue }
            _ = try? await store.upsert(MemoryDocument(
                source: .mail, ref: parts[0],
                title: parts[2],
                body: "Van \(parts[1]): \(parts[2])",
                modified: Date(timeIntervalSince1970: (Double(parts[3]) ?? 0))))
            indexed += 1
            if indexed % 250 == 0 { progressText = "\(indexed) berichten…" }
        }
        progressText = "\(indexed) berichten geïndexeerd"
    }

    /// Called when a conversation ends, so the assistant can recall what it
    /// already told you.
    func remember(conversation messages: [ChatMessage]) async {
        guard enabled.contains(.conversations) else { return }
        let pairs = zip(messages, messages.dropFirst()).filter {
            $0.0.role == .user && $0.1.role == .assistant && !$0.1.text.isEmpty
        }
        for (question, answer) in pairs {
            _ = try? await store.upsert(MemoryDocument(
                source: .conversations, ref: question.id.uuidString,
                title: String(question.text.prefix(80)),
                body: "Vraag: \(question.text)\nAntwoord: \(answer.text)",
                modified: Date()))
        }
    }

    func remember(fact: String, subject: String) async throws {
        _ = try await store.upsert(MemoryDocument(
            source: .facts, ref: subject.lowercased(), title: subject,
            body: fact, modified: Date()))
        await refreshCounts()
    }

    // MARK: - Embeddings

    /// Embeds whatever has no vector yet, in batches. Resumable by design: it
    /// only ever asks for documents that are still missing one.
    func buildEmbeddings() async {
        guard semanticEnabled, busy == nil else { return }
        busy = .facts
        errorText = nil
        defer { busy = nil; progressText = nil }

        do {
            var done = 0
            while true {
                let batch = try await store.documentsWithoutVectors(limit: 32)
                if batch.isEmpty { break }
                let vectors = try await embed(batch.map(\.text))
                guard vectors.count == batch.count else { break }
                for (row, vector) in zip(batch, vectors) {
                    try await store.storeVector(vector, for: row.id)
                }
                done += batch.count
                progressText = "\(done) ingebed…"
            }
            progressText = "\(done) documenten ingebed"
            await refreshCounts()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Kept as an explicit argument even though neither side is prefixed:
    /// asymmetric search models often want different prefixes for documents and
    /// queries, and having the distinction at the call sites means swapping the
    /// model later is a one-line change rather than an audit.
    ///
    /// `embeddinggemma` measured *better* without its documented prefixes here
    /// (0.534 vs 0.444 separation on the same query), so it gets none.
    enum EmbedRole {
        case document, query
    }

    func embed(_ texts: [String], as role: EmbedRole = .document) async throws -> [[Float]] {
        let prefixed = texts
        var request = URLRequest(url: baseURL.appending(path: "/api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.embeddingModel, "input": prefixed,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MemoryError.query("embeddings niet beschikbaar — is \(Self.embeddingModel) opgehaald?")
        }
        struct Reply: Decodable { let embeddings: [[Float]]? }
        guard let vectors = try JSONDecoder().decode(Reply.self, from: data).embeddings else {
            throw MemoryError.query("geen embeddings in het antwoord")
        }
        return vectors
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
