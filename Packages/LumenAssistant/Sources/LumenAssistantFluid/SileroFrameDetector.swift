import FluidAudio
import Foundation
import LumenAssistant

/// Streaming Silero VAD (FluidAudio, Core ML): one 256 ms frame at a time,
/// keeping the model's LSTM state between frames. Uses the same model folder
/// as LumenHearing (`<modelsRoot>/Models/silero-vad`), so nothing extra downloads.
public actor SileroFrameDetector: FrameVoiceDetector {
    public nonisolated let frameSize = VadManager.chunkSize
    private let modelsRoot: URL
    private var manager: VadManager?
    private var state = VadStreamState.initial()

    public init(modelsRoot: URL) { self.modelsRoot = modelsRoot }

    public func prepare() async throws {
        guard manager == nil else { return }
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        manager = try await VadManager(config: VadConfig(defaultThreshold: 0.5), modelDirectory: modelsRoot)
    }

    public func probability(_ frame: [Float]) async throws -> Float {
        try await prepare()
        guard let manager else { return 0 }
        let result = try await manager.processStreamingChunk(frame, state: state)
        state = result.state
        return result.probability
    }

    public func reset() async { state = .initial() }
}
