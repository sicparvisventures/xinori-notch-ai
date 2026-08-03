// AVFAudio predates strict concurrency; AVAudioPCMBuffer is not Sendable even
// though the tap hands us exclusive ownership of each buffer.
@preconcurrency import AVFoundation
import Speech
import SwiftUI

/// On-device speech-to-text.
///
/// Nothing leaves the machine: the models are downloaded once per locale and run
/// locally, which matters when the whole point of the local-first path is that
/// your voice never hits a server.
///
/// Two engines, because neither covers everything. `SpeechTranscriber` is the
/// newer, better one but ships only 30 locales — Dutch is not among them.
/// `DictationTranscriber` covers 54 including `nl_BE` and `nl_NL`. They share a
/// protocol and result shape, so the only thing that differs is which one we
/// hand to the analyzer.
@MainActor
final class Transcriber: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var errorText: String?

    /// Finalized text plus the still-changing tail, so the UI can show words
    /// appearing as they're spoken.
    @Published private(set) var finalized = ""
    @Published private(set) var volatile = ""

    /// Which engine and language the current session actually resolved to —
    /// the UI shows this, because "why is it transcribing me in English" is
    /// otherwise impossible to answer.
    @Published private(set) var activeLocale: Locale?

    var transcript: String {
        (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var speechModule: (any SpeechModule)?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    // MARK: - Engine selection

    private enum Recognizer {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case let .speech(module): return module
            case let .dictation(module): return module
            }
        }
    }

    /// `SpeechTranscriber.supportedLocale(equivalentTo:)` cannot be trusted for
    /// this: asked about `nl_BE` it returns `nl_BE`, even though Dutch is absent
    /// from `supportedLocales` — and the asset download then fails with
    /// "asset unavailable after attempted download". Match against the real list.
    private static func selectRecognizer() async -> Recognizer {
        let wanted = Locale.current

        if let match = best(wanted, in: await SpeechTranscriber.supportedLocales) {
            Log.write("dictation: SpeechTranscriber \(match.identifier)")
            return .speech(SpeechTranscriber(locale: match, preset: .progressiveTranscription))
        }

        if let match = best(wanted, in: await DictationTranscriber.supportedLocales) {
            Log.write("dictation: DictationTranscriber \(match.identifier)")
            return .dictation(DictationTranscriber(locale: match, preset: .progressiveLongDictation))
        }

        Log.write("dictation: no model for \(wanted.identifier), falling back to en_US")
        return .speech(SpeechTranscriber(locale: Locale(identifier: "en_US"),
                                         preset: .progressiveTranscription))
    }

    /// Exact region match first, then any locale sharing the language.
    private static func best(_ wanted: Locale, in supported: [Locale]) -> Locale? {
        func key(_ locale: Locale) -> String {
            locale.identifier.replacingOccurrences(of: "-", with: "_").lowercased()
        }
        if let exact = supported.first(where: { key($0) == key(wanted) }) { return exact }
        guard let language = wanted.language.languageCode?.identifier else { return nil }
        return supported.first { $0.language.languageCode?.identifier == language }
    }

    // MARK: - Permissions

    /// Microphone (TCC) and speech recognition are two separate grants; both are
    /// needed before the analyzer will produce anything.
    static func requestAuthorization() async -> Bool {
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard mic else { return false }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Recording

    func toggle() async {
        isRecording ? await stop() : await start()
    }

    func start() async {
        guard !isRecording else { return }
        errorText = nil
        finalized = ""
        volatile = ""

        guard await Self.requestAuthorization() else {
            errorText = "Microfoon- of spraaktoegang geweigerd."
            return
        }

        do {
            let recognizer = await Self.selectRecognizer()
            let module = recognizer.module
            speechModule = module
            activeLocale = (module as? any LocaleDependentSpeechModule)?.selectedLocales.first

            // The locale's model may not be on the machine yet. This is a
            // one-time download; afterwards it starts instantly.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                Log.write("dictation: downloading locale model…")
                try await request.downloadAndInstall()
            }
            Log.write("dictation: assets ready")

            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [module]
            ) else {
                errorText = "Geen compatibel audioformaat voor spraakherkenning."
                return
            }
            Log.write("dictation: analyzer format \(Int(analyzerFormat.sampleRate))Hz ch\(analyzerFormat.channelCount)")

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            inputContinuation = continuation

            let analyzer = SpeechAnalyzer(modules: [module])
            self.analyzer = analyzer
            try await analyzer.start(inputSequence: stream)

            consumeResults(from: recognizer)
            try startCapture(feeding: continuation, into: analyzerFormat)

            isRecording = true
        } catch {
            Log.write("dictation: failed — \(error.localizedDescription)")
            errorText = error.localizedDescription
            await stop()
        }
    }

    func stop() async {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)

        inputContinuation?.finish()
        inputContinuation = nil

        // Flush whatever audio is still in flight so the last words aren't lost.
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        speechModule = nil

        resultsTask?.cancel()
        resultsTask = nil
        isRecording = false
    }

    // MARK: - Audio

    private func startCapture(
        feeding continuation: AsyncStream<AnalyzerInput>.Continuation,
        into analyzerFormat: AVAudioFormat
    ) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        Log.write("dictation: input format \(Int(inputFormat.sampleRate))Hz ch\(inputFormat.channelCount)")

        // A 0 Hz input format means CoreAudio has no usable capture device yet.
        // Installing a tap with it aborts the process inside AVAudioEngine
        // rather than throwing, so bail out here with something readable.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw LLMError.notReachable("Geen bruikbaar invoerapparaat gevonden.")
        }

        // Built once here rather than inside the tap: the tap runs on a
        // real-time audio thread and must not allocate or touch shared state.
        var converter: AVAudioConverter?
        if inputFormat != analyzerFormat {
            guard let made = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
                // Passing the raw buffer on regardless would hand the analyzer
                // audio in a format it never agreed to.
                throw LLMError.notReachable(
                    "Kan microfoon-audio niet omzetten naar het formaat van de spraakherkenning.")
            }
            made.primeMethod = .none
            converter = made
        }
        let activeConverter = converter

        // Defensive: a tap left behind by a failed previous start would abort
        // the process on the next install.
        input.removeTap(onBus: 0)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            guard let activeConverter else {
                continuation.yield(AnalyzerInput(buffer: buffer))
                return
            }
            guard let converted = Self.convert(buffer, using: activeConverter, to: analyzerFormat) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        engine.prepare()
        try engine.start()
        Log.write("dictation: engine running")
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            // The converter may ask more than once per input buffer; only hand
            // it over the first time, then report starvation.
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    // MARK: - Results

    private func consumeResults(from recognizer: Recognizer) {
        resultsTask = Task { [weak self] in
            do {
                // The two engines publish identical result shapes but through
                // distinct concrete types, so the sequences can't be unified.
                switch recognizer {
                case let .speech(module):
                    for try await result in module.results {
                        self?.apply(String(result.text.characters), isFinal: result.isFinal)
                    }
                case let .dictation(module):
                    for try await result in module.results {
                        self?.apply(String(result.text.characters), isFinal: result.isFinal)
                    }
                }
            } catch is CancellationError {
                // Expected on stop().
            } catch {
                self?.errorText = error.localizedDescription
            }
        }
    }

    private func apply(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
    }
}
