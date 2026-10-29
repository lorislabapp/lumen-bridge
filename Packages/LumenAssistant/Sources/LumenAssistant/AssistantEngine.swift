import Foundation
import LumenHearing

/// What happened to one utterance.
public struct AssistantOutcome: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Dropped: gate closed, no wake phrase, not a command… Audio and text are gone.
        case ignored(String)
        case executed
        case previewed
        case answered
        case proposed
        case refused(RefusalReason)
        case failed(String)
        case undone
    }

    public var kind: Kind
    public var reply: String?
    public var plan: ActionPlan?
    public var auditSeq: Int?
    public var timing: Timing?

    public struct Timing: Sendable, Equatable {
        /// Speech recognition of the utterance.
        public var asrMs: Double
        /// Wake + parse (+ LLM when used).
        public var understandMs: Double
        /// Policy + Home Assistant calls.
        public var actMs: Double
        /// Endpoint (VAD close) → action sent.
        public var totalMs: Double
        public var usedLLM: Bool
    }

    static func ignored(_ why: String) -> AssistantOutcome { AssistantOutcome(kind: .ignored(why)) }
}

/// listen → understand → act. One per Hub; utterances from all cameras pass
/// through it, so duplicates heard by two cameras are caught once.
public actor AssistantEngine {
    public struct Dependencies: Sendable {
        public var settings: @Sendable () async -> AssistantSettings
        public var hearing: @Sendable () async -> HearingSettings
        public var registry: @Sendable () async -> DeviceRegistry
        public var proAllows: @Sendable () async -> Bool
        public var recognizer: (any TranscriptionEngine)?
        public var language: HearingLanguage
        public var backend: (any HomeBackend)?
        public var llm: (any CommandLLM)?
        public var speaker: any UtteranceSpeakerIdentifier
        public var presence: any PresenceOracle
        public var notifier: (any AssistantNotifier)?
        public var speech: any SpeechOutput
        public var verifier: any ActionVerifier
        public var wake: any WakePhraseSpotter

        public init(settings: @escaping @Sendable () async -> AssistantSettings,
                    hearing: @escaping @Sendable () async -> HearingSettings,
                    registry: @escaping @Sendable () async -> DeviceRegistry,
                    proAllows: @escaping @Sendable () async -> Bool = { true },
                    recognizer: (any TranscriptionEngine)?, language: HearingLanguage = .automatic,
                    backend: (any HomeBackend)?, llm: (any CommandLLM)? = nil,
                    speaker: any UtteranceSpeakerIdentifier = NoSpeakerIdentifier(),
                    presence: any PresenceOracle = UnknownPresence(),
                    notifier: (any AssistantNotifier)? = nil, speech: any SpeechOutput = NoSpeechOutput(),
                    verifier: any ActionVerifier = NoOpVerifier(), wake: any WakePhraseSpotter = TranscriptWakeSpotter()) {
            self.settings = settings
            self.hearing = hearing
            self.registry = registry
            self.proAllows = proAllows
            self.recognizer = recognizer
            self.language = language
            self.backend = backend
            self.llm = llm
            self.speaker = speaker
            self.presence = presence
            self.notifier = notifier
            self.speech = speech
            self.verifier = verifier
            self.wake = wake
        }
    }

    private struct UndoEntry {
        let seq: Int
        let plan: ActionPlan
        let calls: [ServiceCall]
        let camera: String
        let room: String?
        let deadline: ContinuousClock.Instant
        let mode: AssistantMode
        let speaker: String
    }

    private let deps: Dependencies
    private let audit: AuditLog
    private let proposals: ProposalBook
    private let parser = RuleParser()
    private var limiter = RateLimiter()
    private var undo: UndoEntry?
    private let clock = ContinuousClock()
    private(set) public var recentTimings: [AssistantOutcome.Timing] = []
    private var observers: [@Sendable (AssistantOutcome) -> Void] = []

    public init(dependencies: Dependencies, audit: AuditLog, proposals: ProposalBook) {
        deps = dependencies
        self.audit = audit
        self.proposals = proposals
    }

    public func observe(_ handler: @escaping @Sendable (AssistantOutcome) -> Void) { observers.append(handler) }

    // MARK: Gate

    /// Listening is allowed for this camera right now: assistant on, camera
    /// opted in, and LumenHearing's own gate open (indoor, consent, no staff).
    public func isListening(camera: String) async -> Bool {
        let settings = await deps.settings()
        guard settings.enabled, settings.cameras.contains(camera) else { return false }
        guard await deps.hearing().eligibility(camera: camera) == .allowed else { return false }
        return await deps.proAllows()
    }

    // MARK: Utterances

    /// Full path from audio. The audio and its text live only in this call.
    public func handle(_ utterance: Utterance) async -> AssistantOutcome {
        guard await isListening(camera: utterance.camera) else { return finish(.ignored("gate closed")) }
        guard let recognizer = deps.recognizer else { return finish(.ignored("no recognizer")) }
        let t0 = clock.now
        let transcript: EngineTranscript
        do { transcript = try await recognizer.transcribe(utterance.audio, language: deps.language) } catch {
            return finish(.ignored("asr failed"))
        }
        let asr = Self.ms(t0.duration(to: clock.now))
        return await understand(transcript.text, camera: utterance.camera, audio: utterance.audio,
                                endedAt: utterance.endedAt, asrMs: asr)
    }

    /// From text (tests, or a future push-to-talk client that sends text).
    public func handle(text: String, camera: String, audio: PCMAudio? = nil,
                       endedAt: ContinuousClock.Instant = .now) async -> AssistantOutcome {
        guard await isListening(camera: camera) else { return finish(.ignored("gate closed")) }
        return await understand(text, camera: camera, audio: audio, endedAt: endedAt, asrMs: 0)
    }

    private func understand(_ text: String, camera: String, audio: PCMAudio?, endedAt: ContinuousClock.Instant,
                            asrMs: Double) async -> AssistantOutcome {
        let started = clock.now
        let settings = await deps.settings()
        let registry = await deps.registry()
        let language = ReplyPhrases.language(of: text)

        // "non, annule" inside the undo window, from the same room.
        if let entry = undo, clock.now < entry.deadline, UndoPhrase.matches(text),
           camera == entry.camera || registry.room(forCamera: camera)?.name == entry.room {
            return await performUndo(entry, language: language)
        }

        // Wake phrase, or natural mode.
        var mode = AssistantMode.wakePhrase
        var commandText: String
        if let match = deps.wake.spot(transcript: text, audio: audio) {
            commandText = match.remainder
            guard !commandText.isEmpty else { return finish(.ignored("wake only")) }
        } else if settings.mode == .natural {
            mode = .natural
            commandText = text
        } else {
            return finish(.ignored("no wake phrase"))
        }

        // Rules first, LLM only when unsure.
        var usedLLM = false
        var result = parser.parse(commandText, registry: registry, camera: camera)
        let room = registry.room(forCamera: camera)?.name
        // The LLM sees only what rules could not place: an unclear target, or (after
        // "Lumen,") a request phrased without a known verb ("fais briller le sapin").
        let askLLM: Bool = switch result {
        case .unsure: true
        case .notACommand(.noVerb): mode == .wakePhrase
        default: false
        }
        if askLLM, settings.llmEnabled, let llm = deps.llm {
            usedLLM = true
            if let interpretation = try? await llm.interpret(commandText, registry: registry, room: room) {
                result = LLMCommandInterpreter.command(from: interpretation, registry: registry, room: room)
                if mode == .natural, !interpretation.addressedToHouse { result = .notACommand(.noVerb) }
            }
        }
        guard case .command(var command) = result else {
            // Not a request: nothing is kept.
            return finish(.ignored("not a command"))
        }
        if command.plan.room == nil { command.plan.room = room }

        // Natural mode: is it addressed to the house?
        var addressScore = 1.0
        if mode == .natural {
            addressScore = AddressClassifier.ruleScore(command, wordCount: commandText.split(separator: " ").count)
            if addressScore < settings.naturalThreshold, !usedLLM, settings.llmEnabled, let llm = deps.llm {
                usedLLM = true
                if let check = try? await llm.interpret(commandText, registry: registry, room: room) {
                    addressScore = check.addressedToHouse ? check.confidence : 0
                }
            }
        }
        let understandMs = Self.ms(started.duration(to: clock.now))

        // Context the policy needs, fetched only when it matters.
        let actStart = clock.now
        let plan = command.plan
        var speaker = SpeakerStanding.notIdentified
        if plan.tier >= .t1 || mode == .natural, let audio {
            speaker = await deps.speaker.identify(audio, camera: camera)
        }
        var person: Bool?
        var mediaPlaying = false
        if mode == .natural {
            let roomCameras = Set((registry.room(forCamera: camera)?.cameras ?? []) + [camera])
            person = await deps.presence.personSeen(cameras: Array(roomCameras), within: 20)
            mediaPlaying = await Self.mediaPlaying(in: room, registry: registry, backend: deps.backend)
        }
        let context = PolicyContext(camera: camera, mode: mode, speaker: speaker, personSeenInRoom: person,
                                    mediaPlayingInRoom: mediaPlaying, addressScore: addressScore, source: command.source)
        var decision = PolicyEngine(settings: settings).decide(plan, context: context)
        if decision == .execute || decision == .propose, let reason = limiter.admit(plan, at: Date()) {
            if reason == .duplicate { return finish(.ignored("duplicate")) }
            decision = .refuse(reason)
        }

        var outcome: AssistantOutcome
        switch decision {
        case .refuse(let reason):
            let seq = try? await audit.append(outcome: .refused, camera: camera, mode: mode, speaker: speaker.label,
                                             plan: plan, source: command.source, command: nil, reason: reason.rawValue).seq
            outcome = AssistantOutcome(kind: .refused(reason), reply: nil, plan: plan, auditSeq: seq)
        case .answer:
            outcome = await answer(plan, camera: camera, mode: mode, speaker: speaker, command: command, text: commandText,
                                   language: language)
        case .propose:
            outcome = await propose(plan, camera: camera, mode: mode, speaker: speaker, command: command, text: commandText,
                                    language: language, dryRun: settings.dryRun)
        case .execute:
            outcome = await execute(plan, camera: camera, mode: mode, speaker: speaker, command: command, text: commandText,
                                    language: language, settings: settings, registry: registry, endedAt: endedAt)
        }
        let actMs = Self.ms(actStart.duration(to: clock.now))
        let timing = AssistantOutcome.Timing(asrMs: asrMs, understandMs: understandMs, actMs: actMs,
                                             totalMs: asrMs + Self.ms(started.duration(to: clock.now)), usedLLM: usedLLM)
        outcome.timing = timing
        recentTimings.append(timing)
        if recentTimings.count > 50 { recentTimings.removeFirst() }
        if let reply = outcome.reply, settings.speakReplies { await deps.speech.speak(reply, language: language, camera: camera) }
        return finish(outcome)
    }

    // MARK: Acting

    private func execute(_ plan: ActionPlan, camera: String, mode: AssistantMode, speaker: SpeakerStanding,
                         command: ParsedCommand, text: String, language: String, settings: AssistantSettings,
                         registry: DeviceRegistry, endedAt: ContinuousClock.Instant) async -> AssistantOutcome {
        let before = await states(for: plan)
        let calls = ServiceMapper.calls(for: plan, states: before)
        guard !calls.isEmpty else {
            return AssistantOutcome(kind: .failed("no service for this device"), plan: plan)
        }
        if settings.dryRun {
            let seq = try? await audit.append(outcome: .previewed, camera: camera, mode: mode, speaker: speaker.label, plan: plan,
                                             source: command.source, command: text,
                                             reason: calls.map { "\($0.domain).\($0.service)" }.joined(separator: ","),
                                             latencyMs: Self.ms(endedAt.duration(to: clock.now)).rounded().asInt).seq
            let reply = ReplyPhrases.preview(plan, language: language)
            if settings.notifyPhone {
                await deps.notifier?.notify(AssistantNotice(kind: .preview, title: "Lumen", body: reply, camera: camera))
            }
            return AssistantOutcome(kind: .previewed, reply: reply, plan: plan, auditSeq: seq)
        }
        guard let backend = deps.backend else { return AssistantOutcome(kind: .failed("Home Assistant not connected"), plan: plan) }
        do {
            for call in calls { try await backend.call(call) }
        } catch {
            _ = try? await audit.append(outcome: .failed, camera: camera, mode: mode, speaker: speaker.label, plan: plan,
                                       source: command.source, command: text, reason: String(describing: error))
            return AssistantOutcome(kind: .failed(String(describing: error)), plan: plan)
        }
        let latency = Self.ms(endedAt.duration(to: clock.now))
        let entry = try? await audit.append(outcome: .executed, camera: camera, mode: mode, speaker: speaker.label, plan: plan,
                                           source: command.source, command: text, latencyMs: latency.rounded().asInt)
        if let entry, let inverse = ServiceMapper.inverse(of: plan, before: before) {
            undo = UndoEntry(seq: entry.seq, plan: plan, calls: inverse, camera: camera, room: plan.room,
                             deadline: clock.now.advanced(by: .seconds(settings.undoSeconds)), mode: mode,
                             speaker: speaker.label)
        }
        let reply = ReplyPhrases.done(plan, language: language)
        if settings.notifyPhone {
            await deps.notifier?.notify(AssistantNotice(kind: .done, title: "Lumen", body: reply, camera: camera))
        }
        for request in VerificationPlanner.requests(for: plan, registry: registry, now: Date()) {
            await deps.verifier.verify(request)
        }
        return AssistantOutcome(kind: .executed, reply: reply, plan: plan, auditSeq: entry?.seq)
    }

    private func answer(_ plan: ActionPlan, camera: String, mode: AssistantMode, speaker: SpeakerStanding,
                        command: ParsedCommand, text: String, language: String) async -> AssistantOutcome {
        let states = await states(for: plan)
        guard !states.isEmpty else { return AssistantOutcome(kind: .failed("state unavailable"), plan: plan) }
        let reply = ReplyPhrases.answer(plan, states: states, language: language)
        let seq = try? await audit.append(outcome: .answered, camera: camera, mode: mode, speaker: speaker.label, plan: plan,
                                         source: command.source, command: text).seq
        return AssistantOutcome(kind: .answered, reply: reply, plan: plan, auditSeq: seq)
    }

    private func propose(_ plan: ActionPlan, camera: String, mode: AssistantMode, speaker: SpeakerStanding,
                         command: ParsedCommand, text: String, language: String, dryRun: Bool) async -> AssistantOutcome {
        let now = Date()
        let proposal = ActionProposal(plan: plan, effect: .destructive, createdAt: now,
                                      expiresAt: now.addingTimeInterval(30), camera: camera, speaker: speaker.label)
        let (title, body) = ReplyPhrases.proposal(plan, language: language)
        if dryRun {
            let seq = try? await audit.append(outcome: .previewed, camera: camera, mode: mode, speaker: speaker.label, plan: plan,
                                             source: command.source, command: text, reason: "would propose (T2)").seq
            return AssistantOutcome(kind: .previewed, reply: body, plan: plan, auditSeq: seq)
        }
        await proposals.add(proposal)
        let seq = try? await audit.append(outcome: .proposed, camera: camera, mode: mode, speaker: speaker.label, plan: plan,
                                         source: command.source, command: text, reason: proposal.id.uuidString).seq
        await deps.notifier?.notify(AssistantNotice(kind: .proposal, title: title, body: body, camera: camera,
                                                    proposalID: proposal.id))
        return AssistantOutcome(kind: .proposed, reply: body, plan: plan, auditSeq: seq)
    }

    /// Runs a T2 proposal after the owner confirmed on the iPhone (receipt).
    public func confirm(_ receipt: ConfirmationReceipt) async -> AssistantOutcome {
        let proposal: ActionProposal
        do { proposal = try await proposals.redeem(receipt) } catch {
            return finish(AssistantOutcome(kind: .failed(String(describing: error))))
        }
        guard let backend = deps.backend else { return finish(AssistantOutcome(kind: .failed("Home Assistant not connected"))) }
        let calls = ServiceMapper.calls(for: proposal.plan, states: [:])
        do { for call in calls { try await backend.call(call) } } catch {
            return finish(AssistantOutcome(kind: .failed(String(describing: error)), plan: proposal.plan))
        }
        let seq = try? await audit.append(outcome: .confirmed, camera: proposal.camera, mode: .wakePhrase,
                                         speaker: proposal.speaker ?? "unknown", plan: proposal.plan, source: .rules,
                                         command: nil, reason: proposal.id.uuidString).seq
        return finish(AssistantOutcome(kind: .executed, reply: ReplyPhrases.done(proposal.plan, language: "fr"),
                                       plan: proposal.plan, auditSeq: seq))
    }

    // MARK: Undo

    /// Undo from the Hub UI (audit viewer) or the "annule" phrase.
    public func undoLast() async -> AssistantOutcome {
        guard let entry = undo, clock.now < entry.deadline else { return finish(.ignored("nothing to undo")) }
        return await performUndo(entry, language: "fr")
    }

    public var canUndo: Bool { if let undo { clock.now < undo.deadline } else { false } }

    private func performUndo(_ entry: UndoEntry, language: String) async -> AssistantOutcome {
        undo = nil
        guard let backend = deps.backend else { return finish(AssistantOutcome(kind: .failed("Home Assistant not connected"))) }
        do { for call in entry.calls { try await backend.call(call) } } catch {
            return finish(AssistantOutcome(kind: .failed(String(describing: error)), plan: entry.plan))
        }
        let seq = try? await audit.append(outcome: .undone, camera: entry.camera, mode: entry.mode, speaker: entry.speaker,
                                         plan: entry.plan, source: .rules, command: nil, reverses: entry.seq).seq
        let reply = ReplyPhrases.undone(language: language)
        let settings = await deps.settings()
        if settings.notifyPhone {
            await deps.notifier?.notify(AssistantNotice(kind: .undone, title: "Lumen", body: reply, camera: entry.camera))
        }
        if settings.speakReplies { await deps.speech.speak(reply, language: language, camera: entry.camera) }
        return finish(AssistantOutcome(kind: .undone, reply: reply, plan: entry.plan, auditSeq: seq))
    }

    // MARK: Helpers

    private func states(for plan: ActionPlan) async -> [String: HAEntity] {
        guard let backend = deps.backend else { return [:] }
        var out: [String: HAEntity] = [:]
        for device in plan.targets {
            if let state = try? await backend.state(device.entityID) { out[device.entityID] = state }
        }
        return out
    }

    static func mediaPlaying(in room: String?, registry: DeviceRegistry, backend: (any HomeBackend)?) async -> Bool {
        guard let backend, let room else { return false }
        let key = KeywordMatcher.normalize(room)
        let players = registry.devices.filter { ($0.kind == .tv || $0.kind == .media) && KeywordMatcher.normalize($0.room ?? "") == key }
        for player in players {
            if let state = try? await backend.state(player.entityID), ["playing", "on"].contains(state.state) { return true }
        }
        return false
    }

    private func finish(_ outcome: AssistantOutcome) -> AssistantOutcome {
        for observer in observers { observer(outcome) }
        return outcome
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}

extension Double {
    var asInt: Int { Int(self) }
}
