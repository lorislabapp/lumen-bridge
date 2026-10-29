import Foundation
import NaturalLanguage

public enum EngineReadiness: Sendable, Equatable {
    case ready
    /// The model is not on this Mac yet; `prepare` downloads it.
    case notDownloaded
    case unsupported(String)
}

/// A speech-to-text engine. The Hub keeps ONE shared instance per engine and
/// feeds it from a serial queue — never one model per camera.
public protocol TranscriptionEngine: Sendable {
    var kind: EngineKind { get }
    func readiness() async -> EngineReadiness
    /// Downloads/compiles/loads what the engine needs. Safe to call repeatedly.
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws
    /// `audio` is 16 kHz mono. Segment times are relative to `audio`.
    func transcribe(_ audio: PCMAudio, language: HearingLanguage) async throws -> EngineTranscript
}

/// Phase 2 seam (diarization / named voices). The no-op stage computes and
/// stores nothing. `VoiceAttributor` (Voices/) is the real one.
public protocol SpeakerAttributionStage: Sendable {
    func attribute(_ transcript: EngineTranscript, audio: PCMAudio) async throws -> EngineTranscript
    /// Same, with the event and the map from `audio` time back to clip time.
    func attribute(_ transcript: EngineTranscript, audio: PCMAudio, context: SpeakerContext) async throws -> EngineTranscript
}

extension SpeakerAttributionStage {
    public func attribute(_ transcript: EngineTranscript, audio: PCMAudio, context: SpeakerContext) async throws -> EngineTranscript {
        try await attribute(transcript, audio: audio)
    }
}

/// What a speaker stage knows about the job it runs in.
public struct SpeakerContext: Sendable {
    public var event: SpeechEvent
    /// Gated (speech-only) audio time → original clip time.
    public var sourceTime: @Sendable (TimeInterval) -> TimeInterval

    public init(event: SpeechEvent, sourceTime: @escaping @Sendable (TimeInterval) -> TimeInterval = { $0 }) {
        self.event = event
        self.sourceTime = sourceTime
    }
}

public struct NoSpeakerAttribution: SpeakerAttributionStage {
    public init() {}
    public func attribute(_ transcript: EngineTranscript, audio: PCMAudio) async throws -> EngineTranscript { transcript }
}

/// One timed word from an engine.
public struct TimedWord: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Float?
    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public enum TranscriptSegmenter {
    /// Groups words into readable segments: split on a pause, after a
    /// sentence end, or when a segment grows too long.
    public static func segments(from words: [TimedWord], pause: TimeInterval = 0.8,
                                maxDuration: TimeInterval = 12) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [TimedWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
                .replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: " .", with: ".")
                .trimmingCharacters(in: .whitespaces)
            let confidences = current.compactMap(\.confidence)
            let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Float(confidences.count)
            if !text.isEmpty { out.append(.init(start: first.start, end: last.end, text: text, confidence: confidence)) }
            current.removeAll()
        }
        for word in words where !word.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let last = current.last, let first = current.first,
               word.start - last.end > pause || word.end - first.start > maxDuration {
                flush()
            }
            current.append(word)
            if let char = word.text.last, ".?!…".contains(char) { flush() }
        }
        flush()
        return out
    }
}

public enum LanguageGuess {
    /// Dominant language of a transcript among the Hub's languages, or nil
    /// when the text is too short or ambiguous.
    public static func detect(_ text: String, candidates: [NLLanguage] = [.french, .english]) -> String? {
        guard text.split(separator: " ").count >= 3 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = candidates
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.6 else { return nil }
        return language.rawValue
    }
}
