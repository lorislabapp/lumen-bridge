import Foundation

/// A stretch of a clip that contains speech, in seconds from the clip start.
public struct SpeechRegion: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
    public var duration: TimeInterval { max(0, end - start) }
}

/// Voice activity detection: which parts of a clip are worth transcribing.
public protocol VoiceActivityGate: Sendable {
    var name: String { get }
    func speechRegions(in audio: PCMAudio) async throws -> [SpeechRegion]
}

/// Dependency-free fallback gate (frame energy with hangover). Used when the
/// Silero model is not on disk yet, and in tests. Silero is the default.
public struct EnergyVoiceGate: VoiceActivityGate {
    public let name = "energy"
    public var thresholdDBFS: Float
    public var minSpeech: TimeInterval
    public var hangover: TimeInterval

    public init(thresholdDBFS: Float = -45, minSpeech: TimeInterval = 0.25, hangover: TimeInterval = 0.4) {
        self.thresholdDBFS = thresholdDBFS
        self.minSpeech = minSpeech
        self.hangover = hangover
    }

    public func speechRegions(in audio: PCMAudio) async throws -> [SpeechRegion] {
        let frame = Int(PCMAudio.sampleRate * 0.03)
        guard audio.samples.count >= frame else { return [] }
        let frameSeconds = Double(frame) / PCMAudio.sampleRate
        var regions: [SpeechRegion] = []
        var openStart: TimeInterval?
        var lastVoiced: TimeInterval = 0
        var index = 0
        while index + frame <= audio.samples.count {
            var energy: Float = 0
            for i in index..<(index + frame) { energy += audio.samples[i] * audio.samples[i] }
            let rms = (energy / Float(frame)).squareRoot()
            let db = 20 * log10(max(rms, 1e-9))
            let t = Double(index) / PCMAudio.sampleRate
            if db >= thresholdDBFS {
                if openStart == nil { openStart = t }
                lastVoiced = t + frameSeconds
            } else if let start = openStart, t - lastVoiced > hangover {
                if lastVoiced - start >= minSpeech { regions.append(.init(start: start, end: lastVoiced)) }
                openStart = nil
            }
            index += frame
        }
        if let start = openStart, lastVoiced - start >= minSpeech { regions.append(.init(start: start, end: lastVoiced)) }
        return regions
    }
}

/// Speech-only audio cut from a clip, with the map back to clip time so
/// segment timestamps stay true to the original event.
public struct GatedAudio: Sendable {
    public struct Piece: Sendable, Equatable {
        public let sourceStart: TimeInterval
        public let gatedStart: TimeInterval
        public let duration: TimeInterval
    }
    public let audio: PCMAudio
    public let pieces: [Piece]

    /// Converts a time in the gated audio back to the original clip timeline.
    public func sourceTime(_ gated: TimeInterval) -> TimeInterval {
        guard let piece = pieces.last(where: { $0.gatedStart <= gated }) else { return pieces.first?.sourceStart ?? gated }
        return piece.sourceStart + min(gated - piece.gatedStart, piece.duration)
    }

    public var speechSeconds: TimeInterval { pieces.reduce(0) { $0 + $1.duration } }
}

public enum SpeechCompactor {
    /// Pads and merges regions, then concatenates them with a short silence
    /// between pieces so the recogniser still sees word boundaries.
    public static func compact(_ audio: PCMAudio, regions: [SpeechRegion], padding: TimeInterval = 0.25,
                               joinGap: TimeInterval = 0.3) -> GatedAudio {
        let total = audio.duration
        let padded = regions
            .map { SpeechRegion(start: max(0, $0.start - padding), end: min(total, $0.end + padding)) }
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        var merged: [SpeechRegion] = []
        for region in padded {
            if let last = merged.last, region.start <= last.end + joinGap {
                merged[merged.count - 1].end = max(last.end, region.end)
            } else {
                merged.append(region)
            }
        }
        let rate = PCMAudio.sampleRate
        let gapSamples = [Float](repeating: 0, count: Int(joinGap * rate))
        var samples: [Float] = []
        var pieces: [GatedAudio.Piece] = []
        for (i, region) in merged.enumerated() {
            if i > 0 { samples.append(contentsOf: gapSamples) }
            let from = max(0, min(audio.samples.count, Int(region.start * rate)))
            let to = max(from, min(audio.samples.count, Int(region.end * rate)))
            pieces.append(.init(sourceStart: Double(from) / rate, gatedStart: Double(samples.count) / rate,
                                duration: Double(to - from) / rate))
            samples.append(contentsOf: audio.samples[from..<to])
        }
        return GatedAudio(audio: PCMAudio(samples: samples), pieces: pieces)
    }
}
