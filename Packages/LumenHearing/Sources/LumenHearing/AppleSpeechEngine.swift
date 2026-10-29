import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Apple SpeechAnalyzer + SpeechTranscriber (macOS 26+). Zero download in the
/// app (the system manages the model), fully on-device, French and English.
/// One analysis at a time (the queue is serial), so the system's conservative
/// analyzer cap is respected; `insufficientResources` is surfaced as a
/// retryable `HearingError` and `ignoresResourceLimits` is never set.
@available(macOS 26.0, *)
public actor AppleSpeechEngine: TranscriptionEngine {
    public nonisolated let kind = EngineKind.appleSpeech
    private let preferredLanguages: [String]

    public init(preferredLanguages: [String] = Locale.preferredLanguages) {
        self.preferredLanguages = preferredLanguages
    }

    /// fr or en; "automatic" follows the Mac's first fr/en preference.
    func locale(for language: HearingLanguage) -> Locale {
        switch language {
        case .french: return Locale(identifier: "fr_FR")
        case .english: return Locale(identifier: "en_US")
        case .automatic:
            let first = preferredLanguages.lazy.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
                .first { $0 == "fr" || $0 == "en" }
            return Locale(identifier: first == "fr" ? "fr_FR" : "en_US")
        }
    }

    public func readiness() async -> EngineReadiness {
        guard SpeechTranscriber.isAvailable else { return .unsupported("SpeechTranscriber unavailable on this Mac") }
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        let wanted = Set(["fr-FR", "en-US"])
        return wanted.isSubset(of: Set(installed)) ? .ready : .notDownloaded
    }

    public func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        for language in [HearingLanguage.french, .english] {
            try await ensureAssets(for: locale(for: language))
        }
        progress?(1)
    }

    private func ensureAssets(for locale: Locale) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw HearingError.engineUnavailable("Locale \(locale.identifier) not supported")
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    public func transcribe(_ audio: PCMAudio, language: HearingLanguage) async throws -> EngineTranscript {
        let first = try await transcribe(audio, locale: locale(for: language))
        guard language == .automatic else { return first }
        // SpeechTranscriber has no language ID. Live UAT 0.18 run: an English
        // clip through the French model gave 8% WER ("I le the package"); the
        // same clip in English gave 0%. When the text reads as the other
        // language, run once more in that language (cheap: ~0.02 RTF).
        let firstCode = first.language
        guard let guessed = LanguageGuess.detect(first.text), guessed != firstCode,
              let other = HearingLanguage(rawValue: guessed) else { return first }
        var second = try await transcribe(audio, locale: locale(for: other))
        second.processingSeconds += first.processingSeconds
        return second.text.isEmpty ? first : second
    }

    private func transcribe(_ audio: PCMAudio, locale requested: Locale) async throws -> EngineTranscript {
        let started = ContinuousClock.now
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw HearingError.engineUnavailable("Locale \(requested.identifier) not supported")
        }
        try await ensureAssets(for: locale)
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .utility, modelRetention: .lingering))
        // Wrong-format audio yields no error and no text: always convert.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let buffer = try Self.buffer(audio, convertedTo: format) else {
            throw HearingError.decodeFailed
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        let collector = Task { () throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let range = result.range
                let start = range.start.isNumeric ? range.start.seconds : 0
                let end = range.end.isNumeric ? range.end.seconds : start
                segments.append(TranscriptSegment(start: start, end: end, text: text))
            }
            return segments
        }
        do {
            if let last = try await analyzer.analyzeSequence(stream) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw Self.map(error)
        }
        let segments: [TranscriptSegment]
        do { segments = try await collector.value } catch { throw Self.map(error) }
        let elapsed = started.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let text = segments.map(\.text).joined(separator: " ")
        return EngineTranscript(text: text, segments: segments,
                                language: locale.language.languageCode?.identifier,
                                engine: .appleSpeech, audioSeconds: audio.duration, processingSeconds: seconds)
    }

    static func map(_ error: Error) -> Error {
        if let hearing = error as? HearingError { return hearing }
        let ns = error as NSError
        if ns.domain == SFSpeechError.errorDomain, ns.code == SFSpeechError.Code.insufficientResources.rawValue {
            return HearingError.insufficientResources
        }
        return HearingError.engineUnavailable(String(describing: type(of: error)))
    }

    /// 16 kHz mono Float32 → the analyzer's preferred format.
    static func buffer(_ audio: PCMAudio, convertedTo target: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMAudio.sampleRate,
                                         channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(audio.samples.count))
        else { return nil }
        input.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { src in
            input.floatChannelData![0].update(from: src.baseAddress!, count: audio.samples.count)
        }
        if source == target { return input }
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(audio.samples.count) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil else { throw HearingError.decodeFailed }
        return output
    }
}
