import Foundation

/// One Frigate audio event with the `speech` label.
public struct SpeechEvent: Sendable, Hashable, Codable {
    public let id: String
    public let camera: String
    public let start: Date
    /// `nil` while Frigate is still recording the event.
    public let end: Date?

    public init(id: String, camera: String, start: Date, end: Date?) {
        self.id = id
        self.camera = camera
        self.start = start
        self.end = end
    }

    /// Frigate event ids are `<epoch>.<frac>-<random>`; camera names are
    /// `[A-Za-z0-9_-]`. Anything else is refused before it reaches a URL or the DB.
    public var isWellFormed: Bool {
        Self.isSafeIdentifier(id, extra: [45, 46, 95]) && Self.isSafeIdentifier(camera, extra: [45, 95])
    }

    static func isSafeIdentifier(_ value: String, extra: Set<UInt8>) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128, value != ".", value != ".." else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || extra.contains($0) }
    }
}

/// 16 kHz mono Float32 samples, the input every engine and the VAD expect.
public struct PCMAudio: Sendable, Equatable {
    public static let sampleRate: Double = 16_000
    public var samples: [Float]

    public init(samples: [Float]) { self.samples = samples }

    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
    public static func silence(seconds: Double) -> PCMAudio {
        PCMAudio(samples: [Float](repeating: 0, count: Int(seconds * sampleRate)))
    }
}

/// Which speech-to-text engine produced a transcript.
public enum EngineKind: String, Sendable, Codable, CaseIterable {
    /// NVIDIA Parakeet TDT 0.6B v3 (CC-BY-4.0) through FluidAudio, Core ML / ANE.
    case parakeetV3 = "parakeet-tdt-0.6b-v3"
    /// Apple SpeechAnalyzer + SpeechTranscriber (macOS 26+), system-managed model.
    case appleSpeech = "apple-speechtranscriber"
}

/// A timed piece of a transcript. `speaker` stays `nil` in Phase 1: it is the
/// seam for diarization (Phase 2) and is never filled from a voiceprint here.
public struct TranscriptSegment: Sendable, Hashable, Codable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var confidence: Float?
    public var speaker: String?

    public init(start: TimeInterval, end: TimeInterval, text: String, confidence: Float? = nil, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.speaker = speaker
    }
}

/// What an engine returns for one clip. Times are relative to the audio it was given.
public struct EngineTranscript: Sendable, Equatable {
    public var text: String
    public var segments: [TranscriptSegment]
    /// BCP-47 language code ("fr", "en") when known.
    public var language: String?
    public var engine: EngineKind
    public var audioSeconds: Double
    public var processingSeconds: Double
    /// Timed words when the engine has them (Parakeet). Lets diarization split
    /// a segment where the speaker changes. Not stored.
    public var words: [TimedWord] = []

    public init(text: String, segments: [TranscriptSegment], language: String?, engine: EngineKind,
                audioSeconds: Double, processingSeconds: Double) {
        self.text = text
        self.segments = segments
        self.language = language
        self.engine = engine
        self.audioSeconds = audioSeconds
        self.processingSeconds = processingSeconds
    }

    /// Real-time factor: processing time / audio time (lower is faster; 0.05 = 20× real time).
    public var realTimeFactor: Double { audioSeconds > 0 ? processingSeconds / audioSeconds : 0 }
}

/// A stored transcript, as read back from `TranscriptStore`.
public struct TranscriptRecord: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let eventID: String
    public let camera: String
    public let start: Date
    public let end: Date?
    public let language: String?
    public let text: String
    public let engine: String
    public let created: Date
    public let segments: [TranscriptSegment]
    /// FTS5 snippet with matches wrapped in `[` `]`; only set by search.
    public let snippet: String?
}

public enum HearingError: Error, Equatable, Sendable {
    case noAudioTrack
    case audioTooLong
    case decodeFailed
    case engineUnavailable(String)
    /// SpeechAnalyzer refused a new analysis (system resource cap). Retry later.
    case insufficientResources
    case modelNotReady
    case invalidEvent
    case storage(String)
}
