@preconcurrency import CoreML
import FluidAudio
import Foundation
import LumenHearing

/// pyannote community-1 offline diarization (segmentation + WeSpeaker
/// ResNet34 embeddings + PLDA/VBx clustering, CC-BY-4.0, Core ML conversion
/// by FluidInference) through FluidAudio's `OfflineDiarizerManager`.
/// One shared, lazily loaded model; calls run one at a time on this actor.
/// Models live in `<modelsRoot>/Models/speaker-diarization` (≈ 21 MB, pinned revision).
public actor FluidSpeakerDiarizer: SpeakerDiarizer {
    /// `OfflineDiarizerManager` is a non-Sendable class; this actor is its
    /// only owner and serialises every call, so handing it across is safe.
    private final class Box: @unchecked Sendable {
        let manager: OfflineDiarizerManager
        init(_ manager: OfflineDiarizerManager) { self.manager = manager }
    }

    private let modelsRoot: URL
    private var box: Box?
    private var loading: Task<Box, Error>?

    public init(modelsRoot: URL) { self.modelsRoot = modelsRoot }

    private var modelsDirectory: URL { modelsRoot.appendingPathComponent("Models", isDirectory: true) }
    private var repoDirectory: URL {
        modelsDirectory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    public var isDownloaded: Bool {
        let fm = FileManager.default
        let required = ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc", "plda-parameters.json"]
        return required.allSatisfy { fm.fileExists(atPath: repoDirectory.appendingPathComponent($0).path) }
    }

    public func readiness() async -> EngineReadiness {
        #if arch(arm64)
        if box != nil || isDownloaded { return .ready }
        return .notDownloaded
        #else
        return .unsupported("Diarization needs Apple Silicon")
        #endif
    }

    public func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        _ = try await loaded(progress: progress)
    }

    private func loaded(progress: (@Sendable (Double) -> Void)?) async throws -> Box {
        if let box { return box }
        if let loading { return try await loading.value }
        let directory = modelsDirectory
        let task = Task<Box, Error> {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var handler: ProgressHandler?
            if let progress { handler = { (p: DownloadProgress) in progress(p.fractionCompleted) } }
            let models = try await OfflineDiarizerModels.load(from: directory, progressHandler: handler)
            let manager = OfflineDiarizerManager(config: .default)
            manager.initialize(models: models)
            return Box(manager)
        }
        loading = task
        do {
            let ready = try await task.value
            box = ready
            loading = nil
            return ready
        } catch {
            loading = nil
            throw HearingError.engineUnavailable("diarizer: \(String(describing: type(of: error)))")
        }
    }

    public func diarize(_ audio: PCMAudio) async throws -> Diarization {
        let box = try await loaded(progress: nil)
        let started = ContinuousClock.now
        // community-1 needs a few seconds of context; pad very short clips with silence.
        var samples = audio.samples
        let minimum = Int(PCMAudio.sampleRate * 3)
        if samples.count < minimum { samples += [Float](repeating: 0, count: minimum - samples.count) }
        let result = try await box.manager.process(audio: samples)
        let elapsed = started.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return Self.map(result, audioSeconds: audio.duration, processingSeconds: seconds)
    }

    static func map(_ result: DiarizationResult, audioSeconds: Double, processingSeconds: Double) -> Diarization {
        let turns = result.segments.map {
            SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: min(audioSeconds, Double($0.endTimeSeconds)))
        }.filter { $0.duration > 0 }
        var seen: [String] = []
        for turn in turns where !seen.contains(turn.speaker) { seen.append(turn.speaker) }
        let speakers = seen.map { id -> DiarizedSpeaker in
            let centroid = result.speakerDatabase?[id] ?? result.segments.first { $0.speakerId == id }?.embedding
            return DiarizedSpeaker(label: id, embedding: centroid.flatMap(VoiceVector.init),
                                   speechSeconds: turns.filter { $0.speaker == id }.reduce(0) { $0 + $1.duration })
        }
        return Diarization(turns: turns, speakers: speakers, audioSeconds: audioSeconds, processingSeconds: processingSeconds)
    }
}
