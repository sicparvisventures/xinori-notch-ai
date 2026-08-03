import AppKit
import Foundation

/// Detects and prepares the local stack: is Ollama installed, is it running,
/// and is a usable model pulled.
///
/// Everything here is observable so onboarding can show live state instead of
/// telling the user to go check for themselves.
@MainActor
final class OllamaSetup: ObservableObject {
    enum Step: Equatable {
        case checking
        case notInstalled
        case installedNotRunning
        case runningNoModel
        case ready(models: [String])

        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    @Published private(set) var step: Step = .checking
    @Published private(set) var pullProgress: Double?
    @Published private(set) var pullStatus: String?
    @Published private(set) var errorText: String?

    /// The model onboarding installs. Deliberately a pinned tag rather than
    /// `latest`: tool calling is the whole point here, and an unpinned tag can
    /// silently move to a build that doesn't support it.
    nonisolated static let defaultModel = "qwen3:8b"

    private let baseURL = URL(string: "http://127.0.0.1:11434")!

    /// Homebrew and the official installer put the binary in different places,
    /// and a GUI app doesn't inherit the user's shell PATH.
    private let candidatePaths = [
        "/usr/local/bin/ollama",
        "/opt/homebrew/bin/ollama",
        "/usr/bin/ollama",
    ]

    var binaryPath: String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isAppInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Ollama.app") || binaryPath != nil
    }

    // MARK: - Detection

    func refresh() async {
        errorText = nil

        guard isAppInstalled else {
            step = .notInstalled
            return
        }

        guard let models = try? await fetchModels() else {
            step = .installedNotRunning
            return
        }

        step = models.isEmpty ? .runningNoModel : .ready(models: models)
    }

    private func fetchModels() async throws -> [String] {
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        var request = URLRequest(url: baseURL.appending(path: "/api/tags"))
        request.timeoutInterval = 3
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name)
    }

    // MARK: - Actions

    func openDownloadPage() {
        NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
    }

    /// Launching the app starts the background server too, which is what the
    /// API actually needs.
    func launchOllama() async {
        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            _ = try? await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/Applications/Ollama.app"),
                configuration: NSWorkspace.OpenConfiguration())
        } else if let binaryPath {
            // No app bundle (Homebrew install): start the server directly and
            // let it outlive this call.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = ["serve"]
            try? process.run()
        }

        // The server takes a moment to bind its port.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(400))
            if (try? await fetchModels()) != nil { break }
        }
        await refresh()
    }

    /// Pull a model, reporting progress. Ollama streams NDJSON with byte
    /// counters, which is the only way to show a real bar for a 5 GB download.
    func pull(_ model: String = OllamaSetup.defaultModel) async {
        pullProgress = 0
        pullStatus = "Verbinden…"
        errorText = nil

        do {
            var request = URLRequest(url: baseURL.appending(path: "/api/pull"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(
                withJSONObject: ["model": model, "stream": true])

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw LLMError.badResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                           body: "kon model niet ophalen")
            }

            for try await line in bytes.lines {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if let message = object["error"] as? String {
                    throw LLMError.notReachable(message)
                }
                if let status = object["status"] as? String {
                    pullStatus = status
                }
                if let total = object["total"] as? Double, total > 0,
                   let completed = object["completed"] as? Double {
                    pullProgress = min(completed / total, 1)
                }
            }

            pullStatus = "Klaar"
            pullProgress = 1
            await refresh()
        } catch {
            errorText = error.localizedDescription
            pullProgress = nil
            pullStatus = nil
        }
    }

    var isPulling: Bool { pullProgress != nil && (pullProgress ?? 0) < 1 }
}
