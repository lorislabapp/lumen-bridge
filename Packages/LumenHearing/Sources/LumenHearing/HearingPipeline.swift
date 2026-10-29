import Foundation

/// Fetches the recorded audio of one speech event (Frigate clip → 16 kHz mono).
public protocol SpeechAudioSource: Sendable {
    func audio(for event: SpeechEvent) async throws -> PCMAudio
}

/// Where keyword alerts go. Implementations must NOT put transcript text or
/// the matched phrase in anything that leaves the Mac (see `KeywordAlert`).
public protocol KeywordAlertSink: Sendable {
    func keywordHeard(_ alert: KeywordAlert) async
}

/// A keyword match. `matchedKeywords` stays on the Mac (local UI only).
public struct KeywordAlert: Sendable, Equatable {
    public let eventID: String
    public let camera: String
    public let detectedAt: Date
    public let matchedKeywords: [String]
}

/// Picks the shared engine for the owner's preference.
public struct EngineSelector: Sendable {
    public var parakeet: (any TranscriptionEngine)?
    public var apple: (any TranscriptionEngine)?

    public init(parakeet: (any TranscriptionEngine)?, apple: (any TranscriptionEngine)?) {
        self.parakeet = parakeet
        self.apple = apple
    }

    public func engine(for preference: EnginePreference) async -> (any TranscriptionEngine)? {
        switch preference {
        case .parakeet: return parakeet
        case .apple: return apple
        case .automatic:
            if let parakeet, await parakeet.readiness() == .ready { return parakeet }
            if let apple {
                if case .unsupported = await apple.readiness() {} else { return apple }
            }
            // Last resort: Parakeet downloads its model on first use.
            return parakeet
        }
    }
}

/// The serial transcription queue. One job runs at a time on one shared
/// engine; safeguards are re-checked before fetching and before transcribing.
public actor HearingPipeline {
    public enum EnqueueResult: Sendable, Equatable {
        case queued, duplicate, full
        case blocked(BlockReason)
    }

    public enum Outcome: Sendable, Equatable {
        case transcribed(id: Int64, keywords: Int)
        case noSpeech
        case skipped(BlockReason)
        case noAudio
        case retrying
        case failed(String)
    }

    public struct Snapshot: Sendable, Equatable {
        public var pending = 0
        public var processing: String?
        public var transcribed = 0
        public var skipped = 0
        public var failed = 0
        public var lastRealTimeFactor: Double?
        public var lastEngine: EngineKind?
        public var lastError: String?
        public init() {}
    }

    public struct Configuration: Sendable {
        public var maxPending = 200
        public var maxAttempts = 3
        public var retryDelay: Duration = .seconds(20)
        public var minimumSpeech: TimeInterval = 0.4
        public init() {}
    }

    private let settings: @Sendable () async -> HearingSettings
    private let audioSource: any SpeechAudioSource
    private let gate: @Sendable () async -> any VoiceActivityGate
    private let engines: EngineSelector
    private let speakers: any SpeakerAttributionStage
    private let store: TranscriptStore
    private let alerts: any KeywordAlertSink
    private let now: @Sendable () -> Date
    private let config: Configuration

    private var queue: [(event: SpeechEvent, attempt: Int)] = []
    private var queuedIDs = Set<String>()
    private var worker: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) public var snapshot = Snapshot()
    private var observers: [UUID: @Sendable (Snapshot) -> Void] = [:]

    public init(settings: @escaping @Sendable () async -> HearingSettings,
                audioSource: any SpeechAudioSource,
                gate: @escaping @Sendable () async -> any VoiceActivityGate,
                engines: EngineSelector,
                speakers: any SpeakerAttributionStage = NoSpeakerAttribution(),
                store: TranscriptStore,
                alerts: any KeywordAlertSink,
                now: @escaping @Sendable () -> Date = { Date() },
                configuration: Configuration = Configuration()) {
        self.settings = settings
        self.audioSource = audioSource
        self.gate = gate
        self.engines = engines
        self.speakers = speakers
        self.store = store
        self.alerts = alerts
        self.now = now
        self.config = configuration
    }

    public func observe(_ handler: @escaping @Sendable (Snapshot) -> Void) {
        observers[UUID()] = handler
        handler(snapshot)
    }

    // MARK: Queue

    public func enqueue(_ event: SpeechEvent) async -> EnqueueResult {
        guard event.isWellFormed else { return .blocked(.cameraNotEnabled) }
        if case .blocked(let reason) = await settings().eligibility(camera: event.camera, eventStart: event.start) {
            // Staff mode and opt-outs drop the event for good: it is never queued for later.
            if reason == .staffPresent { try? await store.markProcessed(eventID: event.id, status: .skipped, at: now()) }
            return .blocked(reason)
        }
        guard !queuedIDs.contains(event.id), snapshot.processing != event.id,
              (try? await store.hasProcessed(eventID: event.id)) != true else { return .duplicate }
        guard queue.count < config.maxPending else { return .full }
        queue.append((event, 1))
        queuedIDs.insert(event.id)
        publish()
        startWorkerIfNeeded()
        return .queued
    }

    /// Drops every queued job (used when the feature, a camera or staff mode changes).
    public func cancelPending() {
        queue.removeAll()
        queuedIDs.removeAll()
        publish()
    }

    /// Waits until the queue is empty and nothing is running.
    public func waitUntilIdle() async {
        if worker == nil && queue.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.runLoop() }
    }

    private func runLoop() async {
        while !queue.isEmpty, !Task.isCancelled {
            let (event, attempt) = queue.removeFirst()
            queuedIDs.remove(event.id)
            snapshot.processing = event.id
            publish()
            let outcome = await process(event)
            snapshot.processing = nil
            switch outcome {
            case .transcribed: snapshot.transcribed += 1
            case .noSpeech, .skipped, .noAudio: snapshot.skipped += 1
            case .failed(let message): snapshot.failed += 1; snapshot.lastError = message
            case .retrying:
                if attempt < config.maxAttempts {
                    try? await Task.sleep(for: config.retryDelay * attempt)
                    if !queuedIDs.contains(event.id) {
                        queue.append((event, attempt + 1))
                        queuedIDs.insert(event.id)
                    }
                } else {
                    snapshot.failed += 1
                    snapshot.lastError = "insufficientResources"
                    try? await store.markProcessed(eventID: event.id, status: .failed, at: now())
                }
            }
            publish()
        }
        worker = nil
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func publish() {
        snapshot.pending = queue.count
        let current = snapshot
        observers.values.forEach { $0(current) }
    }

    // MARK: One job

    /// Runs one event end to end. Internal for tests.
    func process(_ event: SpeechEvent) async -> Outcome {
        // Gate 1: before any audio leaves Frigate.
        if case .blocked(let reason) = await settings().eligibility(camera: event.camera, eventStart: event.start) {
            try? await store.markProcessed(eventID: event.id, status: .skipped, at: now())
            return .skipped(reason)
        }
        let audio: PCMAudio
        do {
            audio = try await audioSource.audio(for: event)
        } catch HearingError.noAudioTrack {
            try? await store.markProcessed(eventID: event.id, status: .skipped, at: now())
            return .noAudio
        } catch {
            try? await store.markProcessed(eventID: event.id, status: .failed, at: now())
            return .failed("audio: \(Self.describe(error))")
        }

        let gated: GatedAudio
        do {
            let regions = try await gate().speechRegions(in: audio)
            gated = SpeechCompactor.compact(audio, regions: regions)
        } catch {
            gated = SpeechCompactor.compact(audio, regions: [SpeechRegion(start: 0, end: audio.duration)])
        }
        guard gated.speechSeconds >= config.minimumSpeech else {
            try? await store.markProcessed(eventID: event.id, status: .noSpeech, at: now())
            return .noSpeech
        }

        // Gate 2: settings may have changed while the clip downloaded (staff arrived, camera turned off).
        let current = await settings()
        if case .blocked(let reason) = current.eligibility(camera: event.camera, eventStart: event.start) {
            try? await store.markProcessed(eventID: event.id, status: .skipped, at: now())
            return .skipped(reason)
        }
        guard let engine = await engines.engine(for: current.engine) else {
            try? await store.markProcessed(eventID: event.id, status: .failed, at: now())
            return .failed("no engine")
        }

        var transcript: EngineTranscript
        do {
            transcript = try await engine.transcribe(gated.audio, language: current.language)
            transcript = try await speakers.attribute(transcript, audio: gated.audio)
        } catch HearingError.insufficientResources {
            return .retrying
        } catch {
            try? await store.markProcessed(eventID: event.id, status: .failed, at: now())
            return .failed("\(engine.kind.rawValue): \(Self.describe(error))")
        }
        snapshot.lastRealTimeFactor = transcript.realTimeFactor
        snapshot.lastEngine = transcript.engine

        // Clip-relative times, so a segment points at the right second of the event.
        transcript.segments = transcript.segments.map {
            var s = $0
            s.start = gated.sourceTime($0.start)
            s.end = max(s.start, gated.sourceTime($0.end))
            return s
        }
        transcript.text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.language == nil || current.language == .automatic {
            transcript.language = LanguageGuess.detect(transcript.text) ?? transcript.language
        }
        guard !transcript.text.isEmpty else {
            try? await store.markProcessed(eventID: event.id, status: .noSpeech, at: now())
            return .noSpeech
        }

        let id: Int64
        do {
            id = try await store.insert(.init(event: event, transcript: transcript, created: now()))
        } catch {
            return .failed("store: \(Self.describe(error))")
        }
        let matched = KeywordMatcher(keywords: current.keywords).matches(in: transcript.text)
        if !matched.isEmpty {
            await alerts.keywordHeard(KeywordAlert(eventID: event.id, camera: event.camera,
                                                   detectedAt: event.start, matchedKeywords: matched))
        }
        return .transcribed(id: id, keywords: matched.count)
    }

    /// Error descriptions never include transcript text or credentials.
    private static func describe(_ error: Error) -> String {
        if let hearing = error as? HearingError { return "\(hearing)" }
        return String(describing: type(of: error))
    }
}
