import Foundation

// Lumen Hub · Phase 2 — who spoke when (diarization) and opt-in named voices.
//
// Ground rules (research 2026-10-29, legal_and_product_layer.md):
// - A stored voice template is GDPR art. 9 biometric data. Only people who
//   gave explicit consent get one; "forget me" erases it.
// - Diarization ("S1", "S2") stores no template and is the default.
// - Voice ID is a soft label. It never unlocks or authorises anything
//   (see `VoiceRights`). No emotion or tone analysis exists anywhere here.
// - Embeddings never leave the Mac: no API here sends them anywhere.

/// A speaker embedding, L2-normalised so cosine similarity is a dot product.
public struct VoiceVector: Sendable, Equatable {
    public let values: [Float]

    /// Returns nil for empty, non-finite or all-zero input.
    public init?(_ raw: [Float]) {
        guard !raw.isEmpty, raw.allSatisfy(\.isFinite) else { return nil }
        let norm = raw.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-6 else { return nil }
        values = raw.map { $0 / norm }
    }

    public var dimension: Int { values.count }

    /// Cosine similarity in [-1, 1]; 0 when the dimensions differ.
    public func cosine(_ other: VoiceVector) -> Float {
        guard values.count == other.values.count else { return 0 }
        var sum: Float = 0
        for i in values.indices { sum += values[i] * other.values[i] }
        return max(-1, min(1, sum))
    }

    /// Weighted mean direction (weights default to 1).
    public static func mean(_ vectors: [VoiceVector], weights: [Float]? = nil) -> VoiceVector? {
        guard let first = vectors.first, vectors.allSatisfy({ $0.dimension == first.dimension }) else { return nil }
        var sum = [Float](repeating: 0, count: first.dimension)
        for (i, v) in vectors.enumerated() {
            let w = weights.map { $0[i] } ?? 1
            for d in sum.indices { sum[d] += v.values[d] * w }
        }
        return VoiceVector(sum)
    }

    /// Little-endian Float32 bytes (sealed before they touch the disk).
    public var data: Data {
        var copy = values
        return Data(bytes: &copy, count: copy.count * MemoryLayout<Float>.size)
    }

    public init?(data: Data) {
        guard data.count >= 4, data.count % 4 == 0 else { return nil }
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        self.init(floats)
    }
}

/// One stretch of one speaker, seconds from the start of the audio it came from.
public struct SpeakerTurn: Sendable, Equatable, Codable {
    public var speaker: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end - start) }

    func overlap(_ start: TimeInterval, _ end: TimeInterval) -> TimeInterval {
        max(0, min(self.end, end) - max(self.start, start))
    }
}

/// One speaker found in one clip, with the clip's mean embedding for them.
public struct DiarizedSpeaker: Sendable, Equatable {
    public var label: String
    public var embedding: VoiceVector?
    public var speechSeconds: TimeInterval

    public init(label: String, embedding: VoiceVector?, speechSeconds: TimeInterval) {
        self.label = label
        self.embedding = embedding
        self.speechSeconds = speechSeconds
    }
}

/// Who spoke when in one clip.
public struct Diarization: Sendable, Equatable {
    public var turns: [SpeakerTurn]
    public var speakers: [DiarizedSpeaker]
    public var audioSeconds: Double
    public var processingSeconds: Double

    public init(turns: [SpeakerTurn], speakers: [DiarizedSpeaker], audioSeconds: Double, processingSeconds: Double) {
        self.turns = turns
        self.speakers = speakers
        self.audioSeconds = audioSeconds
        self.processingSeconds = processingSeconds
    }

    /// Renames speakers S1, S2… in order of first appearance, sorts turns,
    /// drops empty turns and speakers that have none.
    public func normalized() -> Diarization {
        let sorted = turns.filter { $0.duration > 0 }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var rename: [String: String] = [:]
        for turn in sorted where rename[turn.speaker] == nil { rename[turn.speaker] = "S\(rename.count + 1)" }
        let renamedTurns = sorted.map { SpeakerTurn(speaker: rename[$0.speaker]!, start: $0.start, end: $0.end) }
        let renamedSpeakers = speakers.compactMap { s -> DiarizedSpeaker? in
            guard let label = rename[s.label] else { return nil }
            let seconds = renamedTurns.filter { $0.speaker == label }.reduce(0) { $0 + $1.duration }
            return DiarizedSpeaker(label: label, embedding: s.embedding, speechSeconds: seconds)
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        return Diarization(turns: renamedTurns, speakers: renamedSpeakers,
                           audioSeconds: audioSeconds, processingSeconds: processingSeconds)
    }

    /// Real-time factor of the diarization step alone.
    public var realTimeFactor: Double { audioSeconds > 0 ? processingSeconds / audioSeconds : 0 }
}

/// Speaker diarization + per-speaker embeddings for one clip.
public protocol SpeakerDiarizer: Sendable {
    func readiness() async -> EngineReadiness
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws
    /// `audio` is 16 kHz mono. Times in the result are relative to `audio`.
    func diarize(_ audio: PCMAudio) async throws -> Diarization
}

public enum SpeakerLabeler {
    /// Puts S1/S2 labels on transcript segments. With word timings, a segment
    /// is split where the speaker changes; without them, each segment takes
    /// the speaker who talks longest inside it. Times must share one timeline.
    public static func label(_ segments: [TranscriptSegment], words: [TimedWord],
                             turns: [SpeakerTurn]) -> [TranscriptSegment] {
        guard !turns.isEmpty else { return segments }
        if !words.isEmpty {
            var out: [TranscriptSegment] = []
            var run: [TimedWord] = []
            var runSpeaker: String?
            func flush() {
                guard !run.isEmpty else { return }
                for var segment in TranscriptSegmenter.segments(from: run) {
                    segment.speaker = runSpeaker
                    out.append(segment)
                }
                run.removeAll()
            }
            for word in words {
                let speaker = speaker(for: word.start, word.end, in: turns)
                if speaker != runSpeaker { flush(); runSpeaker = speaker }
                run.append(word)
            }
            flush()
            if !out.isEmpty { return out }
        }
        return segments.map { segment in
            var s = segment
            s.speaker = speaker(for: segment.start, segment.end, in: turns)
            return s
        }
    }

    /// Speaker with the most overlap; the nearest turn (≤ 1 s away) when none overlaps.
    static func speaker(for start: TimeInterval, _ end: TimeInterval, in turns: [SpeakerTurn]) -> String? {
        var totals: [String: TimeInterval] = [:]
        for turn in turns { totals[turn.speaker, default: 0] += turn.overlap(start, max(end, start + 0.01)) }
        if let best = totals.filter({ $0.value > 0 }).max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
            return best.key
        }
        let mid = (start + end) / 2
        let nearest = turns.min { distance(mid, $0) < distance(mid, $1) }
        return nearest.flatMap { distance(mid, $0) <= 1 ? $0.speaker : nil }
    }

    private static func distance(_ t: TimeInterval, _ turn: SpeakerTurn) -> TimeInterval {
        t < turn.start ? turn.start - t : (t > turn.end ? t - turn.end : 0)
    }
}
