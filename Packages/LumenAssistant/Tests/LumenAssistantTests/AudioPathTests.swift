import AVFoundation
import CryptoKit
import Foundation
import LumenHearing
import LumenHearingFluid
import Testing
@testable import LumenAssistant
@testable import LumenAssistantFluid

/// Writes an audio file as fragmented MP4 (AAC), like go2rtc's `stream.mp4`,
/// using Apple's own fMP4 writer. Returns the bytes in arrival order.
final class FragmentWriter: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private var data = Data()
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        data.append(segmentData)
    }

    static func fragmentedMP4(from url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .audio)[0]
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
                                                                          AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1])
        reader.add(out)
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 0.5, preferredTimescale: 1000)
        writer.initialSegmentStartTime = .zero
        let sink = FragmentWriter()
        writer.delegate = sink
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000,
        ])
        writer.add(input)
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        while let buffer = out.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            input.append(buffer)
        }
        input.markAsFinished()
        await writer.finishWriting()
        return sink.data
    }
}

/// The models (Parakeet v3 + Silero) live outside the repo; set
/// LUMEN_ASSISTANT_MODELS_DIR=<dir containing Models/> to run real-model tests.
enum Models {
    static var root: URL? {
        guard let dir = ProcessInfo.processInfo.environment["LUMEN_ASSISTANT_MODELS_DIR"], !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: dir, isDirectory: true)
    }
    static var available: Bool { root != nil }
}

@Suite(.serialized) struct AudioPathTests {
    @Test func fmp4DemuxAndAACDecode() async throws {
        let bytes = try await FragmentWriter.fragmentedMP4(from: Fixture.url("cmd-fr-on.m4a"))
        let reference = try await AudioDecoder.decode16kMono(url: Fixture.url("cmd-fr-on.m4a"))
        var demuxer = FMP4AudioDemuxer()
        var frames: [Data] = []
        // Arrives in odd-sized pieces, like a network stream.
        var i = 0
        while i < bytes.count {
            let end = min(bytes.count, i + 1500)
            frames += try demuxer.push(bytes.subdata(in: i..<end))
            i = end
        }
        let track = try #require(demuxer.track)
        #expect(track.sampleRate == 16000)
        #expect(!frames.isEmpty)
        let decoder = try AACDecoder(track: track)
        var samples: [Float] = []
        for start in stride(from: 0, to: frames.count, by: 8) {
            samples += try decoder.decode(Array(frames[start..<min(frames.count, start + 8)]))
        }
        let seconds = Double(samples.count) / 16000
        print("FMP4 frames=\(frames.count) decoded=\(String(format: "%.2f", seconds))s reference=\(String(format: "%.2f", reference.duration))s")
        #expect(abs(seconds - reference.duration) < 0.3)
        let rms = (samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)).squareRoot()
        #expect(rms > 0.005)
    }

    @Test func demuxerRejectsGarbage() throws {
        var d = FMP4AudioDemuxer()
        var junk = Data([0xff, 0xff, 0xff, 0xff]) + Data("moov".utf8)
        junk.append(Data(repeating: 0, count: 16))
        #expect(throws: FMP4Error.malformed) { _ = try d.push(junk) }
    }

    @Test func endpointerCutsUtterancesFromLoopedFile() async throws {
        let source = LoopingFileAudioSource(camera: "salon", url: Fixture.url("cmd-fr-close-undo.m4a"), loops: 2)
        let stream = UtteranceStream(source: source, detector: EnergyFrameDetector())
        let collected = Collected()
        try await stream.run { await collected.add($0) }
        let durations = await collected.items.map { String(format: "%.2f", $0.audio.duration) }
        print("ENDPOINT utterances=\(durations)")
        // Two sentences per loop ("…volets du salon" / "Non, annule"), two loops.
        #expect(await collected.items.count == 4)
    }

    @Test func listeningGateDropsAudio() async throws {
        let source = LoopingFileAudioSource(camera: "salon", url: Fixture.url("cmd-fr-on.m4a"))
        let stream = UtteranceStream(source: source, detector: EnergyFrameDetector(), isListening: { false })
        let collected = Collected()
        try await stream.run { await collected.add($0) }
        #expect(await collected.items.isEmpty)
    }

    // MARK: Real models: looped `say` audio → VAD → ASR → parse → policy → mock HA

    struct E2ECase: Sendable, CustomTestStringConvertible {
        var file: String
        var camera: String
        var expect: [ServiceCall]
        var testDescription: String { file }
    }

    static let e2eCases: [E2ECase] = [
        E2ECase(file: "cmd-fr-on.m4a", camera: "salon", expect: [
            ServiceCall(domain: "light", service: "turn_on", entityID: "light.salon_plafond"),
            ServiceCall(domain: "light", service: "turn_on", entityID: "light.salon_lampe")]),
        E2ECase(file: "cmd-en-off.m4a", camera: "cuisine", expect: [
            ServiceCall(domain: "light", service: "turn_off", entityID: "light.cuisine")]),
        E2ECase(file: "cmd-en-open.m4a", camera: "salon", expect: [
            ServiceCall(domain: "cover", service: "open_cover", entityID: "cover.volets_salon")]),
        // Close, then "Non, annule" 1.5 s later → restore position 100.
        E2ECase(file: "cmd-fr-close-undo.m4a", camera: "salon", expect: [
            ServiceCall(domain: "cover", service: "close_cover", entityID: "cover.volets_salon"),
            ServiceCall(domain: "cover", service: "set_cover_position", entityID: "cover.volets_salon", data: ["position": 100])]),
        // Chatter without the wake phrase: nothing.
        E2ECase(file: "chatter-fr.m4a", camera: "salon", expect: []),
        // T2 from a camera: proposal only (needs a known adult; here unknown → refused). Nothing sent.
        E2ECase(file: "cmd-fr-unlock.m4a", camera: "entree", expect: []),
    ]

    @Test(.enabled(if: Models.available, "set LUMEN_ASSISTANT_MODELS_DIR to run real-model tests"),
          arguments: e2eCases)
    func endToEnd(_ c: E2ECase) async throws {
        let root = try #require(Models.root)
        let parakeet = ParakeetEngine(modelsRoot: root)
        try await parakeet.prepare(progress: nil)
        let silero = SileroFrameDetector(modelsRoot: root)
        try await silero.prepare()
        let backend = MockHomeBackend()
        let deps = AssistantEngine.Dependencies(
            settings: { Fixture.settings() }, hearing: { Fixture.hearing() }, registry: { Fixture.registry },
            recognizer: parakeet, backend: backend)
        let engine = AssistantEngine(dependencies: deps, audit: try AuditLog(url: tempURL("audit.jsonl")),
                                     proposals: ProposalBook(key: SymmetricKey(size: .bits256)))
        // Live path: fMP4 bytes (like go2rtc) → demux → AAC decode → VAD → utterances.
        let bytes = try await FragmentWriter.fragmentedMP4(from: Fixture.url(c.file))
        let source = Go2rtcAudioSource(camera: c.camera) {
            AsyncThrowingStream { continuation in
                var i = 0
                while i < bytes.count {
                    continuation.yield(bytes.subdata(in: i..<min(bytes.count, i + 4096)))
                    i += 4096
                }
                // Trailing silence so the endpointer closes the last sentence.
                continuation.finish()
            }
        }
        let padded = PaddedSource(inner: source, trailingSeconds: 1.5)
        let stream = UtteranceStream(source: padded, detector: silero, isListening: { await engine.isListening(camera: c.camera) })
        let outcomes = Collected2()
        try await stream.run { utterance in
            if ProcessInfo.processInfo.environment["LUMEN_ASSISTANT_DEBUG"] != nil,
               let t = try? await parakeet.transcribe(utterance.audio, language: .automatic) {
                print("E2E-HEARD \(c.file): \(t.text) (\(String(format: "%.2f", utterance.audio.duration)) s)")
            }
            let out = await engine.handle(utterance)
            await outcomes.add(out)
        }
        let calls = await backend.calls
        let report = await outcomes.items.map { o -> String in
            let t = o.timing.map { String(format: "asr=%.0fms understand=%.1fms act=%.1fms total=%.0fms", $0.asrMs, $0.understandMs, $0.actMs, $0.totalMs) } ?? "-"
            return "\(o.kind) \(t)"
        }
        print("E2E \(c.file): \(report)")
        #expect(Set(calls.map { "\($0.service) \($0.entityID) \($0.data)" }) == Set(c.expect.map { "\($0.service) \($0.entityID) \($0.data)" }))
    }

    @Test(.enabled(if: Models.available, "set LUMEN_ASSISTANT_MODELS_DIR to run real-model tests"))
    func realTimeLatency() async throws {
        let root = try #require(Models.root)
        let parakeet = ParakeetEngine(modelsRoot: root)
        try await parakeet.prepare(progress: nil)
        let silero = SileroFrameDetector(modelsRoot: root)
        let backend = MockHomeBackend()
        let deps = AssistantEngine.Dependencies(
            settings: { Fixture.settings() }, hearing: { Fixture.hearing() }, registry: { Fixture.registry },
            recognizer: parakeet, backend: backend)
        let engine = AssistantEngine(dependencies: deps, audit: try AuditLog(url: tempURL("audit.jsonl")),
                                     proposals: ProposalBook(key: SymmetricKey(size: .bits256)))
        // Warm-up (first Core ML run compiles).
        _ = try await parakeet.transcribe(PCMAudio.silence(seconds: 1), language: .automatic)
        let totalsBox = Latencies()
        for file in ["cmd-fr-on.m4a", "cmd-en-off.m4a", "cmd-en-open.m4a"] {
            let source = LoopingFileAudioSource(camera: file.contains("off") ? "cuisine" : "salon", url: Fixture.url(file),
                                                loops: 1, realtime: true, gapSeconds: 1.2)
            let stream = UtteranceStream(source: source, detector: silero)
            let clock = ContinuousClock()
            try await stream.run { u in
                let out = await engine.handle(u)
                if out.kind == .executed {
                    // Endpoint (VAD close) → HA call done.
                    let d = u.endedAt.duration(to: clock.now)
                    await totalsBox.add(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
                }
            }
            await silero.reset()
            try await Task.sleep(for: .seconds(4.5)) // past the duplicate window
        }
        let totals = await totalsBox.values
        let endSilence = Endpointer().endSilence * 1000
        print("LATENCY endpoint→action ms: \(totals.map { String(format: "%.0f", $0) }) (+\(Int(endSilence)) ms end-of-speech silence wait)")
        #expect(totals.count == 3)
        #expect(totals.allSatisfy { $0 < 1500 })
    }
}

/// Appends silence after a source ends (a real camera keeps streaming room noise).
struct PaddedSource: AssistantAudioSource {
    var inner: any AssistantAudioSource
    var trailingSeconds: Double
    var camera: String { inner.camera }
    func chunks() -> AsyncThrowingStream<AudioChunk, Error> {
        let inner = inner, seconds = trailingSeconds
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in inner.chunks() { continuation.yield(chunk) }
                    continuation.yield(AudioChunk(samples: [Float](repeating: 0, count: Int(seconds * 16000))))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

actor Latencies {
    var values: [Double] = []
    func add(_ v: Double) { values.append(v) }
}

actor Collected {
    var items: [Utterance] = []
    func add(_ u: Utterance) { items.append(u) }
}

actor Collected2 {
    var items: [AssistantOutcome] = []
    func add(_ o: AssistantOutcome) { items.append(o) }
}
