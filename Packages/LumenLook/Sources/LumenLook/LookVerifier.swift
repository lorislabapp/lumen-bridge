import CoreGraphics
import Foundation

/// Device state as the device itself reports it (Home Assistant), at check time.
public protocol DeviceStateReader: Sendable {
    func state(of entityID: String) async -> LookState?
}

public struct NoDeviceState: DeviceStateReader {
    public init() {}
    public func state(of entityID: String) async -> LookState? { nil }
}

/// Sends the same command once more (the assistant's executor). False when not
/// allowed (preview mode, rate limit, device gone).
public protocol LookRetrier: Sendable {
    func retry(_ request: LookRequest) async -> Bool
}

public struct NoRetry: LookRetrier {
    public init() {}
    public func retry(_ request: LookRequest) async -> Bool { false }
}

/// Where the owner-facing line goes (push, Hub UI). Text only.
public protocol LookNotifier: Sendable {
    func deliver(_ result: LookResult, target: LookTarget) async
}

public struct NoLookNotifier: LookNotifier {
    public init() {}
    public func deliver(_ result: LookResult, target: LookTarget) async {}
}

public struct LookSettings: Sendable, Equatable {
    public var enabled: Bool
    public var useModel: Bool
    /// Frame height asked from Frigate.
    public var frameHeight: Int
    public init(enabled: Bool = true, useModel: Bool = true, frameHeight: Int = 720) {
        self.enabled = enabled
        self.useModel = useModel
        self.frameHeight = frameHeight
    }
}

/// act → look. One per Hub. `prepare` grabs a "before" frame as the command
/// leaves; `verify` waits for the device's travel time, then checks.
public actor LookVerifier {
    public struct Dependencies: Sendable {
        public var frames: any LookFrameSource
        public var store: LookStore
        public var pose: any CameraPoseChecking
        public var occlusion: any OcclusionChecking
        public var classifier: any StateClassifierSource
        public var judge: (any VisualJudge)?
        public var device: any DeviceStateReader
        public var retrier: any LookRetrier
        public var notifier: any LookNotifier
        public var settings: @Sendable () async -> LookSettings
        /// Injected so tests do not wait 25 s for shutters.
        public var sleep: @Sendable (TimeInterval) async -> Void

        public init(frames: any LookFrameSource, store: LookStore, pose: any CameraPoseChecking = VisionPoseCheck(),
                    occlusion: any OcclusionChecking = VisionHumanOcclusion(),
                    classifier: any StateClassifierSource = NoStateClassifier(), judge: (any VisualJudge)? = nil,
                    device: any DeviceStateReader = NoDeviceState(), retrier: any LookRetrier = NoRetry(),
                    notifier: any LookNotifier = NoLookNotifier(),
                    settings: @escaping @Sendable () async -> LookSettings = { LookSettings() },
                    sleep: @escaping @Sendable (TimeInterval) async -> Void = { s in
                        if s > 0 { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
                    }) {
            self.frames = frames
            self.store = store
            self.pose = pose
            self.occlusion = occlusion
            self.classifier = classifier
            self.judge = judge
            self.device = device
            self.retrier = retrier
            self.notifier = notifier
            self.settings = settings
            self.sleep = sleep
        }
    }

    private let deps: Dependencies
    private var befores: [String: Task<CameraFrame?, Never>] = [:]
    private var running: [String: Task<LookResult?, Never>] = [:]
    private let clock = ContinuousClock()
    private var observers: [@Sendable (LookResult) -> Void] = []

    /// A "before" frame taken this long after the command may already show the change.
    public static let beforeTolerance: TimeInterval = 0.3
    /// TV: second frame this long after the first (is the picture moving?).
    public static let tvMotionGap: TimeInterval = 1.0

    public init(dependencies: Dependencies) { deps = dependencies }

    public func observe(_ handler: @escaping @Sendable (LookResult) -> Void) { observers.append(handler) }

    /// Is there an area for this device? (The assistant words its reply on it.)
    public func covers(_ entityID: String) async -> Bool {
        guard await deps.settings().enabled else { return false }
        return await deps.store.target(entityID)?.enabled == true
    }

    /// Starts fetching the "before" frame; returns at once (the command must not wait).
    public func prepare(_ request: LookRequest) async {
        guard await covers(request.entityID), let target = await deps.store.target(request.entityID) else { return }
        let frames = deps.frames, height = await deps.settings().frameHeight
        befores[request.entityID] = Task { try? await frames.frame(camera: target.camera, height: height) }
    }

    /// Tests: wait until the "before" frame has arrived.
    func waitForBefore(_ entityID: String) async { _ = await befores[entityID]?.value }

    /// Checks in the background; returns at once.
    @discardableResult
    public func verify(_ request: LookRequest) async -> Task<LookResult?, Never>? {
        guard await covers(request.entityID) else { return nil }
        running[request.entityID]?.cancel()
        let task = Task { await self.run(request) }
        running[request.entityID] = task
        return task
    }

    /// "Test" button: check the current state now, no command, no retry, no push.
    public func testNow(_ entityID: String) async -> LookResult? {
        guard let target = await deps.store.target(entityID) else { return nil }
        let reported = await deps.device.state(of: entityID)
        let request = LookRequest(entityID: entityID, expected: reported ?? target.kind.states.positive,
                                  commandAt: Date().addingTimeInterval(-30), language: Locale.current.language.languageCode?.identifier ?? "fr")
        var result = await check(request, target: target, attempt: 0, waitForTravel: false, allowRetry: false)
        result.message = LookPhrases.message(for: result.outcome, kind: target.kind, expected: request.expected,
                                             camera: target.camera, source: result.source, retried: false, language: request.language)
        await deps.store.record(result)
        for o in observers { o(result) }
        return result
    }

    private func run(_ request: LookRequest) async -> LookResult? {
        guard let target = await deps.store.target(request.entityID) else { return nil }
        var result = await check(request, target: target, attempt: 0, waitForTravel: true, allowRetry: true)
        result.message = LookPhrases.message(for: result.outcome, kind: target.kind, expected: request.expected,
                                             camera: target.camera, source: result.source, retried: result.retried,
                                             language: request.language)
        guard !Task.isCancelled else { return nil }
        await deps.store.record(result)
        await deps.notifier.deliver(result, target: target)
        for o in observers { o(result) }
        running[request.entityID] = nil
        return result
    }

    // MARK: One check

    /// The whole pipeline for one attempt. Internal for tests.
    func check(_ request: LookRequest, target: LookTarget, attempt: Int, waitForTravel: Bool,
               allowRetry: Bool, beforeFrame: CameraFrame? = nil) async -> LookResult {
        let settings = await deps.settings()
        let travel = target.travelSeconds > 0 ? target.travelSeconds : request.deadline.timeIntervalSince(request.commandAt)
        if waitForTravel {
            await deps.sleep(max(0, request.commandAt.addingTimeInterval(travel).timeIntervalSinceNow))
        }
        var timing = LookTiming()
        let started = clock.now
        func done(_ decision: PolicyDecision, evidence: String, reported: LookState?, frame: CameraFrame?,
                  proof: CGImage?) async -> LookResult {
            timing.totalMs = Self.ms(started.duration(to: clock.now))
            let proofFile: String? = if let proof { await deps.store.saveProof(proof) } else { nil }
            return LookResult(entityID: target.entityID, camera: target.camera, expected: request.expected,
                              outcome: decision.outcome, source: decision.source, confidence: decision.confidence,
                              evidence: evidence, deviceReported: reported?.rawValue, frameTime: frame?.frameTime,
                              proofFile: proofFile, retried: attempt > 0, timing: timing)
        }
        func unknown(_ reason: UnknownReason, _ evidence: String, frame: CameraFrame? = nil) async -> LookResult {
            await done(PolicyDecision(outcome: .unknown(reason), source: .scene, confidence: 0), evidence: evidence,
                       reported: nil, frame: frame, proof: frame?.image.crop(target.area.expanded(by: 0.25)))
        }

        // 1. The "after" frame, provably newer than the command.
        let height = settings.frameHeight
        let fetchStart = clock.now
        var after: CameraFrame
        do {
            after = try await deps.frames.frame(camera: target.camera, height: height)
            let notBefore = request.commandAt.addingTimeInterval(min(travel * 0.5, 1))
            if let t = after.trustedFrameTime, t < notBefore {
                await deps.sleep(1)
                after = try await deps.frames.frame(camera: target.camera, height: height)
                if let t2 = after.trustedFrameTime, t2 < notBefore {
                    timing.fetchMs = Self.ms(fetchStart.duration(to: clock.now))
                    return await unknown(.staleFrame, "frame time \(t2.timeIntervalSince(request.commandAt))s after command")
                }
            }
        } catch LookFrameError.cameraDisabled {
            return await unknown(.privacyMode, "camera disabled")
        } catch {
            return await unknown(.cameraOffline, "no frame: \(error)")
        }
        timing.fetchMs = Self.ms(fetchStart.duration(to: clock.now))
        var later: CameraFrame?
        if target.kind == .tv {
            await deps.sleep(Self.tvMotionGap)
            let s = clock.now
            later = try? await deps.frames.frame(camera: target.camera, height: height)
            timing.fetchMs += Self.ms(s.duration(to: clock.now))
        }
        var before: CameraFrame? = beforeFrame
        if attempt == 0, let pending = befores.removeValue(forKey: target.entityID), let frame = await pending.value,
           frame.takenAt <= request.commandAt.addingTimeInterval(Self.beforeTolerance) {
            before = frame
        }

        // 2. Can this camera be trusted right now?
        let sceneStart = clock.now
        guard let afterScene = FeatureExtractor.scene(of: after.image) else { return await unknown(.cameraOffline, "bad image") }
        let beforeScene = before.flatMap { FeatureExtractor.scene(of: $0.image) }
        var area = target.area
        var notes: [String] = []
        if afterScene.isTooDark {
            timing.sceneMs = Self.ms(sceneStart.duration(to: clock.now))
            return await unknown(.tooDark, "frame luma \(Int(afterScene.meanLuma))", frame: after)
        }
        if let reference = await deps.store.reference(for: target.entityID), let refScene = FeatureExtractor.scene(of: reference) {
            let differs = refScene.isInfrared != afterScene.isInfrared
            if let pose = await deps.pose.check(reference: reference, current: after.image, lightingDiffers: differs) {
                notes.append(String(format: "shift %.3f%@", pose.shift, pose.featureDistance.map { String(format: " fp %.2f", $0) } ?? ""))
                if pose.moved {
                    timing.sceneMs = Self.ms(sceneStart.duration(to: clock.now))
                    return await unknown(.cameraMoved, notes.joined(separator: ", "), frame: after)
                }
                area = area.offset(dx: pose.dx, dy: pose.dy)
            }
        }
        if SceneJudge.occluded(area, by: await deps.occlusion.occluders(in: after.image)) {
            timing.sceneMs = Self.ms(sceneStart.duration(to: clock.now))
            return await unknown(.occluded, "person in front of the area", frame: after)
        }
        timing.sceneMs = Self.ms(sceneStart.duration(to: clock.now))

        // 3. Pixel test.
        let pixelStart = clock.now
        guard let afterFeatures = FeatureExtractor.features(of: after.image, area: area) else {
            return await unknown(.cameraOffline, "bad crop", frame: after)
        }
        let evidence = PixelEvidence(before: before.flatMap { FeatureExtractor.features(of: $0.image, area: area) },
                                     after: afterFeatures,
                                     afterLater: later.flatMap { FeatureExtractor.features(of: $0.image, area: area) },
                                     beforeScene: beforeScene, afterScene: afterScene, area: area, prior: request.prior)
        let pixels = PixelDetector.read(target.kind, evidence, samples: target.samples)
        timing.pixelsMs = Self.ms(pixelStart.duration(to: clock.now))
        notes.append(pixels.evidence)

        // 4. Frigate classifier for this area, if the owner trained one.
        var classified: (state: LookState, confidence: Double)?
        if let model = target.frigateModel {
            let s = clock.now
            if let reading = await deps.classifier.latest(camera: target.camera, model: model),
               reading.at >= request.commandAt.addingTimeInterval(min(travel * 0.5, 1)),
               let state = target.frigateClassMap[reading.label] ?? LookState(rawValue: reading.label.lowercased()),
               state == target.kind.states.positive || state == target.kind.states.negative {
                classified = (state, reading.score ?? 0.8)
                notes.append("frigate \(reading.label)")
            }
            timing.classifierMs = Self.ms(s.duration(to: clock.now))
        }
        let reported = await deps.device.state(of: target.entityID)
        var input = PolicyInput(expected: request.expected, infrared: afterScene.isInfrared, pixels: pixels,
                                classifier: classified, device: reported, prior: request.prior)

        // 5. Vision model only when unsure.
        if settings.useModel, LookPolicy.needsModel(input), let judge = deps.judge, await judge.isAvailable(),
           let crop = after.image.crop(area.expanded(by: 0.25)) {
            let s = clock.now
            let question = JudgeQuestion(kind: target.kind, deviceName: target.name, expected: request.expected,
                                         prior: request.prior, before: before?.image.crop(area.expanded(by: 0.25)),
                                         after: crop, infrared: afterScene.isInfrared)
            if let answer = try? await judge.judge(question) {
                input.model = answer
                notes.append("model \(answer.state) \(String(format: "%.2f", answer.confidence))")
            } else {
                notes.append("model failed")
            }
            timing.modelMs = Self.ms(s.duration(to: clock.now))
        }
        let decision = LookPolicy.decide(input)
        let proof = after.image.crop(area.expanded(by: 0.25))

        // 6. Learn the look when the camera and the device agree.
        if decision.outcome == .confirmed, decision.confidence >= 0.75, reported == request.expected || decision.source != .pixels {
            await deps.store.learn(target.entityID, state: request.expected, infrared: afterScene.isInfrared, features: afterFeatures)
            if let prior = request.prior, prior != request.expected, pixels.changed == true, let b = evidence.before {
                await deps.store.learn(target.entityID, state: prior, infrared: beforeScene?.isInfrared ?? afterScene.isInfrared, features: b)
            }
        }

        // 7. Contradicted: send once more, then look again. Never on unknown.
        if case .contradicted(let observed) = decision.outcome, allowRetry, attempt == 0 {
            if await deps.retrier.retry(request) {
                var again = request
                again.commandAt = Date()
                again.prior = observed
                // What the camera saw just now is the new "before".
                var second = await check(again, target: target, attempt: 1, waitForTravel: true, allowRetry: false,
                                         beforeFrame: after)
                second.retried = true
                return second
            }
        }
        return await done(decision, evidence: notes.joined(separator: " · "), reported: reported, frame: after, proof: proof)
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
