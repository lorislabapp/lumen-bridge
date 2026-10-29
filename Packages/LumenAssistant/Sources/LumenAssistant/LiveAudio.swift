import Foundation
import LumenHearing

/// A piece of live audio: 16 kHz mono Float32, as it arrives.
public struct AudioChunk: Sendable {
    public var samples: [Float]
    /// When the last sample of this chunk arrived (monotonic).
    public var arrival: ContinuousClock.Instant

    public init(samples: [Float], arrival: ContinuousClock.Instant = .now) {
        self.samples = samples
        self.arrival = arrival
    }
}

/// Live audio of one camera. Implementations: go2rtc fMP4/AAC
/// (`Go2rtcAudioSource`), a looped file for tests and demos.
public protocol AssistantAudioSource: Sendable {
    var camera: String { get }
    func chunks() -> AsyncThrowingStream<AudioChunk, Error>
}

/// Plays a file (any AVFoundation audio) as if it were live, optionally in
/// real time, with silence between loops. Tests and `say` demos.
public struct LoopingFileAudioSource: AssistantAudioSource {
    public let camera: String
    public var url: URL
    public var loops: Int
    public var realtime: Bool
    public var gapSeconds: Double
    public var chunkSeconds: Double

    public init(camera: String, url: URL, loops: Int = 1, realtime: Bool = false, gapSeconds: Double = 1.0,
                chunkSeconds: Double = 0.064) {
        self.camera = camera
        self.url = url
        self.loops = loops
        self.realtime = realtime
        self.gapSeconds = gapSeconds
        self.chunkSeconds = chunkSeconds
    }

    public func chunks() -> AsyncThrowingStream<AudioChunk, Error> {
        let url = url, loops = loops, realtime = realtime, gap = gapSeconds, chunkSeconds = chunkSeconds
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let audio = try await AudioDecoder.decode16kMono(url: url)
                    let silence = [Float](repeating: 0, count: Int(gap * PCMAudio.sampleRate))
                    let size = max(1, Int(chunkSeconds * PCMAudio.sampleRate))
                    for _ in 0..<max(1, loops) {
                        let samples = silence + audio.samples + silence
                        var index = 0
                        while index < samples.count {
                            try Task.checkCancellation()
                            let end = min(samples.count, index + size)
                            if realtime { try await Task.sleep(for: .seconds(Double(end - index) / PCMAudio.sampleRate)) }
                            continuation.yield(AudioChunk(samples: Array(samples[index..<end])))
                            index = end
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Streaming speech probability for fixed frames. Silero (FluidAudio) in the
/// Hub; an energy detector as a dependency-free fallback and in unit tests.
public protocol FrameVoiceDetector: Sendable {
    /// Samples per frame this detector wants (Silero: 4096 = 256 ms).
    var frameSize: Int { get }
    /// Speech probability of the next frame (stateful across calls).
    func probability(_ frame: [Float]) async throws -> Float
    func reset() async
}

public actor EnergyFrameDetector: FrameVoiceDetector {
    public nonisolated let frameSize: Int
    private let thresholdDBFS: Float

    public init(frameSize: Int = 1024, thresholdDBFS: Float = -42) {
        self.frameSize = frameSize
        self.thresholdDBFS = thresholdDBFS
    }

    public func probability(_ frame: [Float]) async throws -> Float {
        guard !frame.isEmpty else { return 0 }
        var energy: Float = 0
        for s in frame { energy += s * s }
        let db = 20 * log10(max((energy / Float(frame.count)).squareRoot(), 1e-9))
        // Smooth ramp around the threshold.
        return max(0, min(1, (db - thresholdDBFS) / 6 + 0.5))
    }

    public func reset() async {}
}

/// One spoken stretch, cut by the endpointer.
public struct Utterance: Sendable {
    public var camera: String
    public var audio: PCMAudio
    /// When speech ended (monotonic). Latency is measured from here.
    public var endedAt: ContinuousClock.Instant
    public var wallClockEnd: Date
}

/// Endpointing: opens on speech, closes after `endSilence` of silence or at
/// `maxDuration`. Keeps a short pre-roll so the first syllable ("Lu…") is not
/// cut. Audio that never becomes an utterance is dropped as it goes.
public struct Endpointer: Sendable {
    public var openThreshold: Float = 0.5
    public var closeThreshold: Float = 0.35
    public var endSilence: Double = 0.6
    public var minSpeech: Double = 0.35
    public var maxDuration: Double = 12
    public var preRoll: Double = 0.3

    private var preBuffer: [Float] = []
    private var current: [Float] = []
    private var inSpeech = false
    private var silenceRun = 0
    private var voicedSamples = 0

    public init() {}

    /// Feeds one frame and its probability. Returns a finished utterance's samples.
    public mutating func feed(_ frame: [Float], probability p: Float) -> [Float]? {
        let rate = PCMAudio.sampleRate
        if !inSpeech {
            preBuffer.append(contentsOf: frame)
            let keep = Int(preRoll * rate) + frame.count
            if preBuffer.count > keep { preBuffer.removeFirst(preBuffer.count - keep) }
            guard p >= openThreshold else { return nil }
            inSpeech = true
            current = preBuffer
            preBuffer = []
            silenceRun = 0
            voicedSamples = frame.count
            return nil
        }
        current.append(contentsOf: frame)
        if p >= closeThreshold {
            silenceRun = 0
            voicedSamples += frame.count
        } else {
            silenceRun += frame.count
        }
        let ended = Double(silenceRun) >= endSilence * rate
        let tooLong = Double(current.count) >= maxDuration * rate
        guard ended || tooLong else { return nil }
        let out = current
        let voiced = voicedSamples
        inSpeech = false
        current = []
        silenceRun = 0
        voicedSamples = 0
        return Double(voiced) >= minSpeech * rate ? out : nil
    }

    /// Drops everything buffered (staff mode, camera switched off).
    public mutating func reset() {
        preBuffer = []
        current = []
        inSpeech = false
        silenceRun = 0
        voicedSamples = 0
    }
}

/// Live chunks → frames → VAD → utterances. One per camera.
public actor UtteranceStream {
    private let source: any AssistantAudioSource
    private let detector: any FrameVoiceDetector
    private var endpointer: Endpointer
    private let isListening: @Sendable () async -> Bool

    public init(source: any AssistantAudioSource, detector: any FrameVoiceDetector, endpointer: Endpointer = Endpointer(),
                isListening: @escaping @Sendable () async -> Bool = { true }) {
        self.source = source
        self.detector = detector
        self.endpointer = endpointer
        self.isListening = isListening
    }

    /// Runs until the source ends or the task is cancelled.
    public func run(_ onUtterance: @escaping @Sendable (Utterance) async -> Void) async throws {
        let frameSize = detector.frameSize
        var pending: [Float] = []
        for try await chunk in source.chunks() {
            try Task.checkCancellation()
            // Gate re-checked on every chunk: staff mode or consent withdrawn stops at once.
            guard await isListening() else {
                pending.removeAll()
                endpointer.reset()
                await detector.reset()
                continue
            }
            pending.append(contentsOf: chunk.samples)
            while pending.count >= frameSize {
                let frame = Array(pending.prefix(frameSize))
                pending.removeFirst(frameSize)
                let p = try await detector.probability(frame)
                if let samples = endpointer.feed(frame, probability: p) {
                    let utterance = Utterance(camera: source.camera, audio: PCMAudio(samples: samples),
                                              endedAt: chunk.arrival, wallClockEnd: Date())
                    await onUtterance(utterance)
                }
            }
        }
    }
}
