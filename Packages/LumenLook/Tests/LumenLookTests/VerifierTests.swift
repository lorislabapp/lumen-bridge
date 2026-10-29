import CoreGraphics
import Foundation
import Testing
@testable import LumenLook

/// End-to-end act→look on synthetic frames: each device, day and night,
/// contradictions with one retry, and every "unknown" reason.
@Suite("Look verifier (synthetic camera)")
struct VerifierTests {
    // MARK: Lights

    @Test func lampTurnsOnConfirmed() async {
        let run = await Fixture.run(.light, from: .off, to: .on, shows: [.on])
        #expect(run.result.outcome == .confirmed)
        #expect(run.result.source == .pixels)
        #expect(run.retries == 0)
        #expect(run.notified.first?.message == "Lumière allumée — vérifié sur la caméra Salon")
        #expect(run.result.proofFile != nil)
    }

    @Test func lampTurnsOffConfirmed() async {
        let run = await Fixture.run(.light, from: .on, to: .off, shows: [.off])
        #expect(run.result.outcome == .confirmed)
    }

    @Test func lampStaysOffIsContradictedAfterOneRetry() async {
        let run = await Fixture.run(.light, from: .off, to: .on, shows: [.off, .off])
        #expect(run.result.outcome == .contradicted(observed: .off))
        #expect(run.retries == 1)
        #expect(run.result.retried)
        #expect(run.notified.count == 1)
        #expect(run.notified[0].message == "Lumière semble toujours éteinte — vue sur la caméra Salon, j'ai réessayé une fois")
    }

    @Test func lampRetrySucceeds() async {
        let run = await Fixture.run(.light, from: .off, to: .on, shows: [.off, .on])
        #expect(run.result.outcome == .confirmed)
        #expect(run.retries == 1)
        #expect(run.result.retried)
    }

    @Test func noRetryWhenRetrierRefuses() async {
        let run = await Fixture.run(.light, from: .off, to: .on, shows: [.off], allowRetry: false)
        #expect(run.result.outcome == .contradicted(observed: .off))
        #expect(run.retries == 1)
        #expect(!run.result.retried)
    }

    @Test func lampAtNightInfrared() async {
        var night = Scene()
        night.night = true
        let run = await Fixture.run(.light, from: .off, to: .on, shows: [.on], base: night)
        #expect(run.result.outcome == .confirmed)
    }

    // MARK: TV

    @Test func tvTurnsOnConfirmed() async {
        let run = await Fixture.run(.tv, from: .off, to: .on, shows: [.on])
        #expect(run.result.outcome == .confirmed)
        #expect(run.frameCalls == 3) // before, after, after + 1 s
    }

    @Test func tvTurnsOffConfirmed() async {
        let run = await Fixture.run(.tv, from: .on, to: .off, shows: [.off])
        #expect(run.result.outcome == .confirmed)
    }

    @Test func tvWithGlareStaysOffNeverConfirmed() async {
        var glare = Scene()
        glare.tvReflection = true
        let run = await Fixture.run(.tv, from: .off, to: .on, shows: [.off, .off], base: glare)
        #expect(run.result.outcome != .confirmed)
        // With the device's own report the failure is certain.
        let reported = await Fixture.run(.tv, from: .off, to: .on, shows: [.off, .off], base: glare, device: .off)
        #expect(reported.result.outcome == .contradicted(observed: .off))
        #expect(reported.retries == 1)
    }

    @Test func tvOnWithoutBeforeFrame() async {
        let run = await Fixture.run(.tv, from: nil, to: .on, shows: [.on], withBefore: false)
        #expect(run.result.outcome == .confirmed)
    }

    // MARK: Shutters

    @Test func shuttersCloseConfirmed() async {
        let run = await Fixture.run(.shutter, from: .open, to: .closed, shows: [.closed])
        #expect(run.result.outcome == .confirmed)
        #expect(run.notified.first?.message == "Volets fermés — vérifié sur la caméra Salon")
    }

    @Test func shuttersOpenConfirmed() async {
        let run = await Fixture.run(.shutter, from: .closed, to: .open, shows: [.open])
        #expect(run.result.outcome == .confirmed)
    }

    @Test func shuttersStuckOpenContradicted() async {
        let run = await Fixture.run(.shutter, from: .open, to: .closed, shows: [.open, .open])
        #expect(run.result.outcome == .contradicted(observed: .open))
        #expect(run.retries == 1)
    }

    @Test func shuttersAtNightSlatsStillShowInInfrared() async {
        var night = Scene()
        night.night = true
        let run = await Fixture.run(.shutter, from: nil, to: .closed, shows: [.closed], base: night, withBefore: false)
        #expect(run.result.outcome == .confirmed)
    }

    @Test func openWindowAtNightIsUnknown() async {
        var night = Scene()
        night.night = true
        let run = await Fixture.run(.shutter, from: nil, to: .open, shows: [.open], base: night, withBefore: false)
        #expect(run.result.outcome == .unknown(.night))
        #expect(run.retries == 0)
        // The model is never trusted alone on an infrared picture: against the pixel lean it changes nothing.
        let judge = StubJudge(JudgeAnswer(visible: true, state: "closed", changed: "unknown", confidence: 0.95))
        let disagree = await Fixture.run(.shutter, from: nil, to: .open, shows: [.open], base: night, withBefore: false, judge: judge)
        #expect(disagree.result.outcome == .unknown(.night))
    }

    // MARK: Doors

    @Test func doorOpensWithKnownPrior() async {
        let run = await Fixture.run(.door, from: .closed, to: .open, shows: [.open])
        #expect(run.result.outcome == .confirmed)
    }

    @Test func doorWithoutPriorIsUnknownWithoutModel() async {
        let run = await Fixture.run(.door, from: nil, to: .open, shows: [.open], withBefore: false)
        #expect(run.result.outcome == .unknown(.unsure))
        #expect(run.notified.first?.message == "Commande envoyée, je ne vois pas la porte (pas sûr)")
    }

    @Test func doorWithoutPriorUsesVisionModel() async {
        let judge = StubJudge(JudgeAnswer(visible: true, state: "open", changed: "unknown", confidence: 0.9))
        let run = await Fixture.run(.door, from: nil, to: .open, shows: [.open], withBefore: false, judge: judge)
        #expect(run.result.outcome == .confirmed)
        #expect(run.result.source == .visionModel)
        #expect(run.judgeAsked == 1)
    }

    @Test func modelNotAskedWhenPixelsAreSure() async {
        let judge = StubJudge(JudgeAnswer(visible: true, state: "off", changed: "no", confidence: 0.9))
        let run = await Fixture.run(.light, from: .off, to: .on, shows: [.on], judge: judge)
        #expect(run.result.outcome == .confirmed)
        #expect(run.judgeAsked == 0)
    }

    @Test func modelSkippedWhenUnreachable() async {
        let judge = StubJudge(JudgeAnswer(visible: true, state: "open", changed: "yes", confidence: 0.9), available: false)
        let run = await Fixture.run(.door, from: nil, to: .open, shows: [.open], withBefore: false, judge: judge)
        #expect(run.result.outcome == .unknown(.unsure))
        #expect(run.judgeAsked == 0)
    }

    @Test func frigateClassifierDecides() async {
        let reading = ClassifierReading(label: "open", score: 0.93, at: Date().addingTimeInterval(30))
        let run = await Fixture.run(.door, from: nil, to: .open, shows: [.open], withBefore: false, classifier: reading,
                                    frigateModel: "porte_garage")
        #expect(run.result.outcome == .confirmed)
        #expect(run.result.source == .frigateClassifier)
    }

    @Test func staleClassifierIgnored() async {
        let reading = ClassifierReading(label: "open", score: 0.93, at: Date().addingTimeInterval(-60))
        let run = await Fixture.run(.door, from: nil, to: .open, shows: [.open], withBefore: false, classifier: reading,
                                    frigateModel: "porte_garage")
        #expect(run.result.outcome == .unknown(.unsure))
    }

    // MARK: Unknown reasons (never retried)

    @Test func privacyMode() async {
        let run = await Fixture.run(.light, from: .off, to: .on, shows: [], steps: [.fail(.cameraDisabled)])
        #expect(run.result.outcome == .unknown(.privacyMode))
        #expect(run.retries == 0)
        #expect(run.notified.first?.message == "Commande envoyée, je ne vois pas la lumière (caméra en mode privé)")
    }

    @Test func cameraOffline() async {
        let run = await Fixture.run(.shutter, from: .open, to: .closed, shows: [], steps: [.fail(.cameraOffline)])
        #expect(run.result.outcome == .unknown(.cameraOffline))
        #expect(run.retries == 0)
    }

    @Test func staleFrameIsUnknown() async {
        let old = Fixture.scene(.light, .on).image()
        let run = await Fixture.run(.light, from: .off, to: .on, shows: [], steps: [.frame(old, offset: -5)])
        #expect(run.result.outcome == .unknown(.staleFrame))
        #expect(run.frameCalls == 2) // one re-fetch
    }

    @Test func untimedFrameUsesFetchTime() async {
        // No X-Frame-Time header: the fetch time (after the command) stands in.
        let img = Fixture.scene(.tv, .on).image()
        let run = await Fixture.run(.tv, from: .off, to: .on, shows: [], withBefore: false,
                                    steps: [.frame(img, offset: 6, timed: false)])
        #expect(run.result.outcome != .unknown(.staleFrame))
        #expect(run.result.frameTime == nil)
    }

    @Test func skewedFrigateClockFallsBackToFetchTime() async {
        // Frigate's clock 30 s ahead: X-Frame-Time is ignored, the fetch time stands in.
        let img = Fixture.scene(.tv, .on).image()
        let t0 = Date()
        let frames = ScriptedFrames(base: t0, [.frame(img, offset: 6)])
        let frame = try? await frames.frame(camera: "salon", height: 720)
        let skewed = CameraFrame(image: img, frameTime: t0.addingTimeInterval(40), fetchedAt: t0.addingTimeInterval(6))
        #expect(frame?.trustedFrameTime != nil)
        #expect(skewed.trustedFrameTime == nil)
        #expect(skewed.takenAt == t0.addingTimeInterval(6))
    }

    @Test func personInFront() async {
        let run = await Fixture.run(.shutter, from: .open, to: .closed, shows: [.closed],
                                    occlusion: [LookRect(x: 0.72, y: 0.05, width: 0.2, height: 0.9)])
        #expect(run.result.outcome == .unknown(.occluded))
        #expect(run.retries == 0)
    }

    @Test func blackFrameTooDark() async {
        var black = Scene()
        black.black = true
        let run = await Fixture.run(.light, from: .off, to: .on, shows: [], steps: [.frame(black.image(), offset: 2)])
        #expect(run.result.outcome == .unknown(.tooDark))
    }

    @Test func cameraMovedAsksToRedraw() async {
        var moved = Scene()
        moved.shiftX = 0.14
        moved.shiftY = 0.06
        let run = await Fixture.run(.shutter, from: .open, to: .closed, shows: [.closed], current: moved, reference: Scene())
        #expect(run.result.outcome == .unknown(.cameraMoved))
        #expect(run.notified.first?.message == "Commande envoyée, je ne vois pas les volets (la caméra a bougé, redessinez la zone)")
    }

    @Test func smallDriftFollowsTheArea() async {
        var drift = Scene()
        drift.shiftX = 0.03
        // Before and after both drifted (camera nudged after the area was drawn).
        let run = await Fixture.run(.shutter, from: .open, to: .closed, shows: [.closed], base: drift, reference: Scene())
        #expect(run.result.outcome == .confirmed)
        #expect(run.result.evidence.contains("shift"))
    }

    @Test func cloudDoesNotLookLikeAMove() async {
        var cloud = Scene()
        cloud.exposure = 0.8
        let run = await Fixture.run(.light, from: .off, to: .on, shows: [.on], base: cloud, reference: Scene())
        #expect(run.result.outcome == .confirmed)
    }

    // MARK: Learning

    @Test func learnedLooksDecideWithoutBefore() async {
        let root = Fixture.tempRoot()
        // A confirmed check the device agrees with teaches both looks.
        let first = await Fixture.run(.door, from: .closed, to: .open, shows: [.open], device: .open, root: root)
        #expect(first.result.outcome == .confirmed)
        let store = LookStore(root: root)
        let learned = await store.target(Fixture.entity(.door))?.samples.keys.sorted() ?? []
        #expect(learned == ["closed-day", "open-day"])
        // Later: no before frame, no prior — the learned looks answer.
        let samples = await store.target(Fixture.entity(.door))!.samples
        let later = await Fixture.run(.door, from: nil, to: .closed, shows: [.closed], seed: 77, withBefore: false, samples: samples)
        #expect(later.result.outcome == .confirmed)
        let wrong = await Fixture.run(.door, from: nil, to: .closed, shows: [.open, .open], seed: 78, withBefore: false, samples: samples)
        #expect(wrong.result.outcome == .contradicted(observed: .open))
    }

    // MARK: English

    @Test func englishMessages() {
        #expect(LookPhrases.message(for: .confirmed, kind: .shutter, expected: .closed, camera: "living_room", source: .pixels,
                                    retried: false, language: "en") == "Shutters closed — checked on the Living Room camera")
        #expect(LookPhrases.message(for: .unknown(.night), kind: .shutter, expected: .closed, camera: "salon", source: .scene,
                                    retried: false, language: "en") == "Command sent, I can't see the shutters (night)")
        #expect(LookPhrases.message(for: .unknown(.night), kind: .shutter, expected: .closed, camera: "salon", source: .scene,
                                    retried: false, language: "fr") == "Commande envoyée, je ne vois pas les volets (nuit)")
        #expect(LookPhrases.message(for: .contradicted(observed: .off), kind: .tv, expected: .on, camera: "salon", source: .device,
                                    retried: true, language: "en") == "TV: the device still reports off, I tried again once")
    }
}

@Test func manualTestUnknownDoesNotClaimACommand() {
    #expect(LookPhrases.message(for: .unknown(.night), kind: .shutter, expected: .closed, camera: "living_room", source: .pixels,
                                retried: false, language: "fr", commandSent: false) == "Je ne vois pas les volets (nuit)")
    #expect(LookPhrases.message(for: .unknown(.night), kind: .shutter, expected: .closed, camera: "living_room", source: .pixels,
                                retried: false, language: "en", commandSent: false) == "I can't see the shutters (night)")
}

