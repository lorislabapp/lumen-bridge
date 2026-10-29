import FluidAudio
import Foundation
import LumenHearing

/// Model locations. The Hub passes its own Application Support folder; tests
/// and dev runs can point `LUMEN_HEARING_MODELS_DIR` at an external volume.
public enum HearingModelLocation {
    public static func root(default fallback: URL) -> URL {
        if let override = ProcessInfo.processInfo.environment["LUMEN_HEARING_MODELS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return fallback
    }
}

/// NVIDIA Parakeet TDT 0.6B v3 (25 European languages incl. French and English,
/// CC-BY-4.0) running on Core ML / the Neural Engine through FluidAudio.
/// One shared, lazily loaded model for every camera.
public actor ParakeetEngine: TranscriptionEngine {
    public nonisolated let kind = EngineKind.parakeetV3
    /// Approximate download size of the int8 v3 bundle, for the UI.
    public static let approximateDownloadBytes: Int64 = 480_000_000

    private let modelsRoot: URL
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    /// `modelsRoot` holds `Models/<repo folder>`; nothing is written elsewhere.
    public init(modelsRoot: URL) {
        self.modelsRoot = modelsRoot
    }

    private var modelDirectory: URL {
        modelsRoot.appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Repo.parakeetV3.folderName, isDirectory: true)
    }

    public func readiness() async -> EngineReadiness {
        #if arch(arm64)
        if manager != nil { return .ready }
        return AsrModels.modelsExist(at: modelDirectory, version: .v3) ? .ready : .notDownloaded
        #else
        return .unsupported("Parakeet needs Apple Silicon")
        #endif
    }

    public func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        _ = try await loadedManager(progress: progress)
    }

    private func loadedManager(progress: (@Sendable (Double) -> Void)?) async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let directory = modelDirectory
        let task = Task<AsrManager, Error> { try await Self.load(directory: directory, progress: progress) }
        loading = task
        do {
            let ready = try await task.value
            manager = ready
            loading = nil
            return ready
        } catch {
            loading = nil
            throw HearingError.engineUnavailable("parakeet: \(String(describing: type(of: error)))")
        }
    }

    private static func load(directory: URL, progress: (@Sendable (Double) -> Void)?) async throws -> AsrManager {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handler: ProgressHandler?
        if let progress {
            handler = { (p: DownloadProgress) in progress(p.fractionCompleted) }
        }
        let models = try await AsrModels.downloadAndLoad(to: directory, version: .v3, progressHandler: handler)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        return manager
    }

    public func transcribe(_ audio: PCMAudio, language: HearingLanguage) async throws -> EngineTranscript {
        let manager = try await loadedManager(progress: nil)
        let started = ContinuousClock.now
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let hint: Language? = switch language {
        case .french: .french
        case .english: .english
        case .automatic: nil
        }
        let result = try await manager.transcribe(audio.samples, decoderState: &state, language: hint)
        let elapsed = started.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let words = Self.words(from: result.tokenTimings ?? [])
        var segments = TranscriptSegmenter.segments(from: words)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if segments.isEmpty, !text.isEmpty {
            segments = [TranscriptSegment(start: 0, end: audio.duration, text: text, confidence: result.confidence)]
        }
        var transcript = EngineTranscript(text: text, segments: segments, language: hint?.rawValue, engine: .parakeetV3,
                                          audioSeconds: audio.duration, processingSeconds: seconds)
        transcript.words = words
        return transcript
    }

    /// SentencePiece tokens → words (a token starting with "▁" or a space opens a new word).
    static func words(from tokens: [TokenTiming]) -> [TimedWord] {
        var words: [TimedWord] = []
        var confidences: [Float] = []
        for token in tokens {
            let piece = token.token
            let opensWord = piece.hasPrefix("▁") || piece.hasPrefix(" ") || words.isEmpty
            let clean = piece.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
            if opensWord {
                if var last = words.last, !confidences.isEmpty {
                    last.confidence = confidences.reduce(0, +) / Float(confidences.count)
                    words[words.count - 1] = last
                }
                confidences = []
                guard !clean.isEmpty else { continue }
                words.append(TimedWord(text: clean, start: token.startTime, end: token.endTime))
            } else if var last = words.last {
                last.text += clean
                last.end = token.endTime
                words[words.count - 1] = last
            }
            confidences.append(token.confidence)
        }
        if var last = words.last, !confidences.isEmpty {
            last.confidence = confidences.reduce(0, +) / Float(confidences.count)
            words[words.count - 1] = last
        }
        return words
    }
}

/// Silero VAD v6 (MIT) through FluidAudio — trims silence before ASR.
public actor SileroVoiceGate: VoiceActivityGate {
    public nonisolated let name = "silero"
    private let modelsRoot: URL
    private var manager: VadManager?

    public init(modelsRoot: URL) { self.modelsRoot = modelsRoot }

    public var isDownloaded: Bool {
        let models = modelsRoot.appendingPathComponent("Models", isDirectory: true)
        guard let items = try? FileManager.default.subpathsOfDirectory(atPath: models.path) else { return false }
        return items.contains { $0.lowercased().contains("silero") && $0.hasSuffix(".mlmodelc") }
    }

    public func prepare() async throws {
        if manager == nil {
            try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
            manager = try await VadManager(config: VadConfig(defaultThreshold: 0.5), modelDirectory: modelsRoot)
        }
    }

    public func speechRegions(in audio: PCMAudio) async throws -> [SpeechRegion] {
        try await prepare()
        guard let manager else { return [] }
        let segments = try await manager.segmentSpeech(audio.samples)
        return segments.map { SpeechRegion(start: $0.startTime, end: $0.endTime) }
    }
}
