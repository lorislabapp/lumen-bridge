import Foundation
import Testing
@testable import LumenHearing

/// Unit vectors at a chosen cosine to the x axis (2-D is enough for scoring rules).
func vec(_ cosine: Float, dims: Int = 4) -> VoiceVector {
    var raw = [Float](repeating: 0, count: dims)
    raw[0] = cosine
    raw[1] = (1 - cosine * cosine).squareRoot()
    return VoiceVector(raw)!
}
let axis = VoiceVector([1, 0, 0, 0])!

@Suite struct VoiceBandTests {
    let t = VoiceThresholds.defaults

    @Test func threeBands() {
        let gallery = [EnrolledVoice(profileID: "marie", camera: "salon", vector: axis)]
        #expect(VoiceMatcher.match(vec(0.90), speechSeconds: 4, gallery: gallery, thresholds: t).band == .match)
        #expect(VoiceMatcher.match(vec(t.match), speechSeconds: 4, gallery: gallery, thresholds: t).band == .match)
        let maybe = VoiceMatcher.match(vec(0.60), speechSeconds: 4, gallery: gallery, thresholds: t)
        #expect(maybe.band == .maybe && maybe.profileID == "marie")
        let unknown = VoiceMatcher.match(vec(0.30), speechSeconds: 4, gallery: gallery, thresholds: t)
        #expect(unknown.band == .unknown && unknown.profileID == nil)
    }

    @Test func shortClipsAreNeverNamed() {
        let gallery = [EnrolledVoice(profileID: "marie", camera: nil, vector: axis)]
        let r = VoiceMatcher.match(axis, speechSeconds: 1.5, gallery: gallery, thresholds: t)
        #expect(r.band == .unknown && r.tooShort)
    }

    @Test func ambiguousLeadIsOnlyMaybe() {
        // Two people both above `match`, too close to call → "maybe" the best.
        let gallery = [EnrolledVoice(profileID: "a", camera: nil, vector: vec(0.99)),
                       EnrolledVoice(profileID: "b", camera: nil, vector: vec(0.97))]
        let r = VoiceMatcher.match(axis, speechSeconds: 5, gallery: gallery, thresholds: t)
        #expect(r.band == .maybe && r.profileID == "a")
    }

    @Test func bestEmbeddingPerPersonCounts() {
        // Marie has a poor living-room sample and a good kitchen sample.
        let gallery = [EnrolledVoice(profileID: "marie", camera: "salon", vector: vec(0.2)),
                       EnrolledVoice(profileID: "marie", camera: "cuisine", vector: vec(0.95))]
        #expect(VoiceMatcher.match(axis, speechSeconds: 5, gallery: gallery, thresholds: t).band == .match)
    }

    @Test func emptyGalleryIsUnknown() {
        #expect(VoiceMatcher.match(axis, speechSeconds: 5, gallery: [], thresholds: t).band == .unknown)
    }

    @Test func thresholdsAreClampedAndOrdered() {
        let bad = VoiceThresholds(match: 0.5, maybe: 0.9, margin: -1, minimumSpeechSeconds: 0, clusterJoin: 2).validated
        #expect(bad.maybe <= bad.match - 0.05)
        #expect(bad.margin == 0 && bad.minimumSpeechSeconds == 1 && bad.clusterJoin <= 0.95)
        #expect(VoiceThresholds.defaults.validated == VoiceThresholds.defaults)
    }

    @Test func vectorsAreNormalisedAndRoundTrip() throws {
        let v = try #require(VoiceVector([3, 4]))
        #expect(abs(v.values[0] - 0.6) < 1e-6)
        #expect(VoiceVector(data: v.data) == v)
        #expect(VoiceVector([0, 0]) == nil)
        #expect(VoiceVector([.nan, 1]) == nil)
        #expect(v.cosine(VoiceVector([1, 0, 0])!) == 0) // dimension mismatch never matches
    }
}

@Suite struct ClusteringTests {
    @Test func joinsNearestAboveThresholdElseNew() {
        let clusters = [VoiceClustering.Centroid(id: 1, vector: axis, events: 3),
                        VoiceClustering.Centroid(id: 2, vector: VoiceVector([0, 1, 0, 0])!, events: 1)]
        #expect(VoiceClustering.nearest(vec(0.8), in: clusters, threshold: 0.6)?.id == 1)
        #expect(VoiceClustering.nearest(VoiceVector([0, 0, 1, 0])!, in: clusters, threshold: 0.6) == nil)
    }

    @Test func runningMeanWeighsEvents() {
        let moved = VoiceClustering.adding(VoiceVector([0, 1, 0, 0])!, to: axis, events: 9)
        #expect(moved.cosine(axis) > 0.99) // one new event barely moves a 9-event cluster
    }

    @Test func mergePlanKeepsBusierAndMergesOncePerPass() {
        let c = [VoiceClustering.Centroid(id: 1, vector: axis, events: 1),
                 VoiceClustering.Centroid(id: 2, vector: vec(0.95), events: 5),
                 VoiceClustering.Centroid(id: 3, vector: vec(0.93), events: 1)]
        let plan = VoiceClustering.mergePlan(c, threshold: 0.9)
        #expect(plan.count == 1)
        #expect(plan.first?.keep == 2 || plan.first?.keep == 1)
        #expect(Set(plan.flatMap { [$0.keep, $0.absorb] }).count == 2)
    }
}

@Suite struct FaceVoiceRuleTests {
    let start = Date(timeIntervalSince1970: 1_000)
    var end: Date { start.addingTimeInterval(10) }
    let one = [DiarizedSpeaker(label: "S1", embedding: axis, speechSeconds: 6)]

    @Test func oneFaceOneVoiceIsACandidate() {
        let faces = [FaceSighting(name: "Marie", start: start.addingTimeInterval(-30), end: start.addingTimeInterval(5))]
        #expect(FaceVoiceRule.candidate(faces: faces, speechStart: start, speechEnd: end, speakers: one) == "Marie")
    }

    @Test func twoFacesOrTwoVoicesOrNoOverlapAssignNothing() {
        let both = [FaceSighting(name: "Marie", start: start, end: end), FaceSighting(name: "Paul", start: start, end: nil)]
        #expect(FaceVoiceRule.candidate(faces: both, speechStart: start, speechEnd: end, speakers: one) == nil)
        let two = one + [DiarizedSpeaker(label: "S2", embedding: axis, speechSeconds: 3)]
        let marie = [FaceSighting(name: "Marie", start: start, end: end)]
        #expect(FaceVoiceRule.candidate(faces: marie, speechStart: start, speechEnd: end, speakers: two) == nil)
        let before = [FaceSighting(name: "Marie", start: start.addingTimeInterval(-100), end: start.addingTimeInterval(-50))]
        #expect(FaceVoiceRule.candidate(faces: before, speechStart: start, speechEnd: end, speakers: one) == nil)
        let sameTwice = [FaceSighting(name: "Marie", start: start, end: end), FaceSighting(name: "Marie ", start: start, end: end)]
        #expect(FaceVoiceRule.candidate(faces: sameTwice, speechStart: start, speechEnd: end, speakers: one) == "Marie")
    }

    @Test func promotesOnlyAfterThreeAgreeingEvents() {
        #expect(FaceVoiceRule.decision(counts: [:]) == .none)
        #expect(FaceVoiceRule.decision(counts: ["Marie": 1]) == .suggest(face: "Marie", agreeing: 1))
        #expect(FaceVoiceRule.decision(counts: ["Marie": 2]) == .suggest(face: "Marie", agreeing: 2))
        #expect(FaceVoiceRule.decision(counts: ["Marie": 3]) == .promote(face: "Marie"))
        // Any disagreeing event blocks auto-promotion.
        #expect(FaceVoiceRule.decision(counts: ["Marie": 4, "Paul": 1]) == .suggest(face: "Marie", agreeing: 4))
        #expect(FaceVoiceRule.decision(counts: ["Marie": 2, "Paul": 2]) == .none)
    }
}

@Suite struct VoiceRightsTests {
    @Test func voiceCanOnlyLowerRights() {
        for granted in VoiceRights.Tier.allCases {
            for speaker in [VoiceRights.Speaker.none, .unknown, .maybe, .adult, .child] {
                #expect(VoiceRights.effectiveTier(granted: granted, speaker: speaker) <= granted)
            }
            #expect(VoiceRights.effectiveTier(granted: granted, speaker: .child) == .viewOnly)
            #expect(VoiceRights.effectiveTier(granted: granted, speaker: .unknown) == .viewOnly)
        }
        #expect(VoiceRights.effectiveTier(granted: .viewOnly, speaker: .adult) == .viewOnly) // a match never raises
    }
}

@Suite struct VoiceGateTests {
    func hearing(camera: String = "salon", placement: CameraPlacement = .indoor) -> HearingSettings {
        var h = HearingSettings()
        h.enabled = true
        try? h.grantConsent(camera: camera, placement: placement, at: Date(timeIntervalSince1970: 0))
        return h
    }

    @Test func decisions() {
        var voices = VoiceSettings()
        #expect(VoiceGate.decision(hearing: hearing(), voices: voices, camera: "salon", proAllowsProcessing: true) == .diarizeOnly)
        voices.identificationEnabled = true
        #expect(VoiceGate.decision(hearing: hearing(), voices: voices, camera: "salon", proAllowsProcessing: true) == .identify)
        voices.excludedCameras = ["salon"]
        #expect(VoiceGate.decision(hearing: hearing(), voices: voices, camera: "salon", proAllowsProcessing: true) == .diarizeOnly)
        voices.excludedCameras = []
        #expect(VoiceGate.decision(hearing: hearing(), voices: voices, camera: "salon", proAllowsProcessing: false) == .off(nil))
        voices.diarizationEnabled = false
        #expect(VoiceGate.decision(hearing: hearing(), voices: voices, camera: "salon", proAllowsProcessing: true) == .off(nil))
    }

    @Test func staffPresentAndOutdoorStopEverything() {
        var voices = VoiceSettings()
        voices.identificationEnabled = true
        var staff = hearing()
        staff.staffPresent = true
        #expect(VoiceGate.decision(hearing: staff, voices: voices, camera: "salon", proAllowsProcessing: true) == .off(.staffPresent))
        #expect(VoiceGate.decision(hearing: hearing(placement: .outdoor), voices: voices, camera: "salon",
                                   proAllowsProcessing: true) == .off(.outdoorLocked))
        #expect(VoiceGate.decision(hearing: hearing(), voices: voices, camera: "jardin", proAllowsProcessing: true)
                == .off(.cameraNotEnabled))
    }

    @Test func settingsDefaultsArePrivateAndDecodeLeniently() throws {
        let fresh = VoiceSettings()
        #expect(fresh.diarizationEnabled && !fresh.identificationEnabled)
        let decoded = try JSONDecoder().decode(VoiceSettings.self, from: Data(#"{"identificationEnabled":true,"thresholds":{"match":2,"maybe":0.1,"margin":0.06,"minimumSpeechSeconds":2,"clusterJoin":0.6}}"#.utf8))
        #expect(decoded.identificationEnabled)
        #expect(decoded.thresholds.match <= VoiceThresholds.range.upperBound)
    }
}

@Suite struct SpeakerLabelerTests {
    let turns = [SpeakerTurn(speaker: "S1", start: 0, end: 3), SpeakerTurn(speaker: "S2", start: 3.4, end: 6)]

    @Test func wordsSplitASegmentAtTheSpeakerChange() {
        let words = [TimedWord(text: "Bonjour", start: 0.2, end: 0.8), TimedWord(text: "Marie", start: 0.9, end: 1.4),
                     TimedWord(text: "Hello", start: 3.5, end: 3.9), TimedWord(text: "there.", start: 4.0, end: 4.4)]
        let merged = [TranscriptSegment(start: 0.2, end: 4.4, text: "Bonjour Marie Hello there.")]
        let out = SpeakerLabeler.label(merged, words: words, turns: turns)
        #expect(out.map(\.speaker) == ["S1", "S2"])
        #expect(out.map(\.text) == ["Bonjour Marie", "Hello there."])
    }

    @Test func segmentsWithoutWordsTakeTheLongestSpeaker() {
        let segments = [TranscriptSegment(start: 0, end: 2.5, text: "a"), TranscriptSegment(start: 2.8, end: 6, text: "b"),
                        TranscriptSegment(start: 9, end: 10, text: "far")]
        #expect(SpeakerLabeler.label(segments, words: [], turns: turns).map(\.speaker) == ["S1", "S2", nil])
    }

    @Test func normalisedLabelsFollowFirstAppearance() {
        let d = Diarization(turns: [SpeakerTurn(speaker: "S2", start: 0, end: 2), SpeakerTurn(speaker: "S1", start: 2, end: 3),
                                    SpeakerTurn(speaker: "S2", start: 3, end: 5)],
                            speakers: [DiarizedSpeaker(label: "S1", embedding: nil, speechSeconds: 0),
                                       DiarizedSpeaker(label: "S2", embedding: axis, speechSeconds: 0)],
                            audioSeconds: 5, processingSeconds: 0.1).normalized()
        #expect(d.turns.map(\.speaker) == ["S1", "S2", "S1"])
        #expect(d.speakers.first { $0.label == "S1" }?.embedding == axis)
        #expect(d.speakers.first { $0.label == "S1" }?.speechSeconds == 4)
    }
}

@Suite struct ProGateTests {
    func cache() -> ProEntitlementCache {
        let suite = "lumenhub.tests.pro.\(UUID().uuidString)"
        return ProEntitlementCache(suiteName: suite)
    }
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func freshProReadEnablesAndIsCached() {
        let c = cache()
        let access = ProGate.evaluate(.success(.init(isPro: true, expiresAt: nil, updatedAt: now)), cache: c, now: now)
        #expect(access == .pro(expiresAt: nil) && access.canEnableNew)
        // Offline two days later: the cached grant still counts.
        let later = ProGate.evaluate(.failure(.init(.offline)), cache: c, now: now.addingTimeInterval(2 * 86_400))
        #expect(later == .cachedPro(verifiedAt: now) && later.canEnableNew)
        // Eight days later: unknown → fail closed for new enablement, but running work continues.
        let stale = ProGate.evaluate(.failure(.init(.offline)), cache: c, now: now.addingTimeInterval(8 * 86_400))
        #expect(stale == .unknown(.offline) && !stale.canEnableNew && stale.allowsProcessing)
    }

    @Test func notProOrExpiredPausesAndClearsCache() {
        let c = cache()
        _ = ProGate.evaluate(.success(.init(isPro: true, expiresAt: nil, updatedAt: now)), cache: c, now: now)
        let off = ProGate.evaluate(.success(.init(isPro: false, expiresAt: nil, updatedAt: now)), cache: c, now: now)
        #expect(off == .notPro && !off.canEnableNew && !off.allowsProcessing)
        #expect(c.validGrant(now: now) == nil)
        let expired = ProGate.evaluate(.success(.init(isPro: true, expiresAt: now.addingTimeInterval(-1), updatedAt: now)),
                                       cache: c, now: now)
        #expect(expired == .notPro)
    }

    @Test func cachedGrantNeverOutlivesTheSubscription() {
        let c = cache()
        _ = ProGate.evaluate(.success(.init(isPro: true, expiresAt: now.addingTimeInterval(3600), updatedAt: now)), cache: c, now: now)
        #expect(ProGate.evaluate(.failure(.init(.offline)), cache: c, now: now.addingTimeInterval(7200)) == .unknown(.offline))
    }

    @Test func missingEntitlementFailsClosed() {
        let access = ProGate.evaluate(.failure(.init(.containerNotEntitled)), cache: cache(), now: now)
        #expect(access == .unknown(.containerNotEntitled) && !access.canEnableNew)
        #expect(ProGate.evaluate(.success(nil), cache: cache(), now: now) == .unknown(.noRecord))
    }
}
