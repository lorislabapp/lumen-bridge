import Foundation
import Testing
@testable import LumenHearing
@testable import LumenHearingFluid

/// Real pyannote community-1 through FluidAudio on synthetic speech
/// (Scripts/make-voice-fixtures.sh: macOS `say`, Thomas FR + Samantha EN,
/// AAC 32 kb/s). Opt-in, needs ≈ 21 MB once from huggingface.co:
/// LUMEN_HEARING_DIARIZER=1 LUMEN_HEARING_MODELS_DIR=/Volumes/... swift test --filter VoiceIntegration
@Suite(.serialized) struct VoiceIntegrationTests {
    struct Truth: Decodable {
        struct Turn: Decodable { let speaker: String; let start: Double; let end: Double }
        let turns: [Turn]
    }

    static var enabled: URL? {
        guard ProcessInfo.processInfo.environment["LUMEN_HEARING_DIARIZER"] == "1",
              let dir = ProcessInfo.processInfo.environment["LUMEN_HEARING_MODELS_DIR"] else { return nil }
        return URL(fileURLWithPath: dir)
    }

    static func fixture(_ name: String, _ ext: String = "m4a") throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Share of ground-truth speech time given to the right speaker, under the
    /// best one-to-one mapping of predicted labels to true speakers.
    static func attributionAccuracy(truth: [Truth.Turn], predicted: [SpeakerTurn]) -> (Double, [String: String]) {
        let step = 0.01
        let labels = Array(Set(predicted.map(\.speaker))).sorted()
        let people = Array(Set(truth.map(\.speaker))).sorted()
        var overlap: [String: [String: Double]] = [:]
        var total = 0.0
        for t in truth {
            var x = t.start
            while x < t.end {
                total += step
                if let p = predicted.first(where: { $0.start <= x && x < $0.end }) { overlap[p.speaker, default: [:]][t.speaker, default: 0] += step }
                x += step
            }
        }
        func permutations(_ a: [String]) -> [[String]] {
            a.count <= 1 ? [a] : a.indices.flatMap { i in permutations(Array(a[..<i] + a[(i + 1)...])).map { [a[i]] + $0 } }
        }
        var best = (0.0, [String: String]())
        for perm in permutations(people) {
            var mapping: [String: String] = [:]
            for (i, label) in labels.enumerated() where i < perm.count { mapping[label] = perm[i] }
            let hit = mapping.reduce(0.0) { $0 + (overlap[$1.key]?[$1.value] ?? 0) }
            if hit > best.0 { best = (hit, mapping) }
        }
        return (total > 0 ? best.0 / total : 0, best.1)
    }

    @Test func diarizesTwoSyntheticSpeakersAndNamesThem() async throws {
        guard let root = Self.enabled else { return }
        let diarizer = FluidSpeakerDiarizer(modelsRoot: root)
        let loadStart = ContinuousClock.now
        try await diarizer.prepare(progress: nil)
        print("[DIAR] prepare (download/compile/load) took \(loadStart.duration(to: .now))")

        let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: try Self.fixture("two-speakers", "json")))
        let audio = try await AudioDecoder.decode16kMono(url: try Self.fixture("two-speakers"))
        _ = try await diarizer.diarize(PCMAudio(samples: Array(audio.samples.prefix(16_000 * 4)))) // warm-up
        var runs: [Double] = []
        var result = try await diarizer.diarize(audio).normalized()
        for _ in 0..<3 {
            let start = ContinuousClock.now
            result = try await diarizer.diarize(audio).normalized()
            runs.append(Self.seconds(start.duration(to: .now)))
        }
        let median = runs.sorted()[1]
        print(String(format: "[DIAR] audio=%.2fs diarize median=%.3fs (%.0fx real time) runs=%@ speakers=%d",
                     audio.duration, median, audio.duration / median,
                     runs.map { String(format: "%.3f", $0) }.joined(separator: ","), result.speakers.count))
        for turn in result.turns { print(String(format: "[DIAR] %@ %.2f–%.2f", turn.speaker, turn.start, turn.end)) }

        #expect(result.speakers.count == 2)
        let (accuracy, mapping) = Self.attributionAccuracy(truth: truth.turns, predicted: result.turns)
        print(String(format: "[DIAR] attribution accuracy=%.1f%%", accuracy * 100), "mapping=\(mapping)")
        #expect(accuracy >= 0.80)

        // Named voices: enrol each voice from three held-out clips (sentences
        // that never occur in the conversation), then match the conversation.
        let store = try VoiceStore(url: nil, sealer: testSealer())
        let enroller = VoiceEnroller(audioSource: SilentSource(), diarizer: diarizer, store: store)
        var ids: [String: String] = [:]
        var enrolled: [String: [VoiceVector]] = [:]
        for (who, name) in [("fr", "Thomas"), ("en", "Samantha")] {
            let p = try await store.addProfile(name: name, isChild: false, consent: VoiceConsent(language: who))
            ids[who] = p.id
            var items: [VoiceStore.NewEmbedding] = []
            for i in 1...3 {
                let clip = try await AudioDecoder.decode16kMono(url: try Self.fixture("voice-\(who)-\(i)"))
                let (vector, seconds) = try await enroller.embedding(of: clip, turns: [SpeakerTurn(speaker: "S1", start: 0, end: clip.duration)])
                let v = try #require(vector)
                enrolled[who, default: []].append(v)
                items.append(.init(vector: v, camera: "salon", source: "event", speechSeconds: seconds))
            }
            try await store.addEmbeddings(profileID: p.id, items)
        }
        let same = (enrolled["fr"]!.map { a in enrolled["fr"]!.map { a.cosine($0) } }.joined().filter { $0 < 0.9999 }
                    + enrolled["en"]!.map { a in enrolled["en"]!.map { a.cosine($0) } }.joined().filter { $0 < 0.9999 })
        let different = enrolled["fr"]!.flatMap { a in enrolled["en"]!.map { a.cosine($0) } }
        print(String(format: "[VOICE] enrolment clips: same-voice cosine min=%.3f mean=%.3f · different-voice max=%.3f mean=%.3f",
                     same.min() ?? 0, same.reduce(0, +) / Float(max(1, same.count)),
                     different.max() ?? 0, different.reduce(0, +) / Float(max(1, different.count))))

        let gallery = try await store.gallery()
        for speaker in result.speakers {
            let v = try #require(speaker.embedding)
            let m = VoiceMatcher.match(v, speechSeconds: speaker.speechSeconds, gallery: gallery, thresholds: .defaults)
            let expected = ids[mapping[speaker.label] ?? ""]
            let scores = gallery.map { String(format: "%.3f", v.cosine($0.vector)) }.joined(separator: " ")
            print("[VOICE] \(speaker.label) → band=\(m.band) score=\(m.score.map { String(format: "%.3f", $0) } ?? "-") scores=[\(scores)]")
            #expect(m.profileID == expected)
            #expect(m.band == .match)
        }
    }
}
