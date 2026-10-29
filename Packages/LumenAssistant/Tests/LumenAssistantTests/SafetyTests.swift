import CryptoKit
import Foundation
import Testing
@testable import LumenAssistant

@Suite struct WakeTests {
    let spotter = TranscriptWakeSpotter()

    @Test(arguments: [
        ("Lumen, allume la lumière du salon", "allume la lumiere du salon"),
        ("lumen turn off the kitchen light", "turn off the kitchen light"),
        ("Dis Lumen, ferme les volets", "ferme les volets"),
        ("Hey Lumen open the shutters", "open the shutters"),
        ("Lumène, éteins la télé", "eteins la tele"),
        ("Loumen allume", "allume"),
        ("Lu men, allume la lampe", "allume la lampe"),
        ("Lumens turn on the TV", "turn on the tv"),
        ("Lumin, baisse le son", "baisse le son"),
        ("Lumaine, allume la lumière du salon.", "allume la lumiere du salon"),
        ("L'humaine déverrouille la porte d'entrée.", "deverrouille la porte d entree"),
    ])
    func spots(_ heard: String, _ remainder: String) {
        #expect(spotter.spot(transcript: heard, audio: nil)?.remainder == remainder)
    }

    @Test(arguments: [
        "allume la lumière du salon",
        "la lumière du salon est trop forte",
        "lumière, allume-toi",
        "Lemon cake is ready",
        "the human turned off the light",
        "On a acheté une lampe Lumen hier",
        "Je pense que Lumen va allumer la lumière",
        "women in the kitchen",
    ])
    func ignores(_ heard: String) {
        #expect(spotter.spot(transcript: heard, audio: nil) == nil)
    }

    @Test func undoPhrases() {
        for yes in ["Non, annule", "annule", "Annule ça", "Cancel", "cancel that", "undo", "non annule s'il te plaît", "Lumen, annule"] {
            #expect(UndoPhrase.matches(yes), "\(yes)")
        }
        for no in ["annule le rendez-vous de demain", "allume la lumière", "non", "cancel my subscription"] {
            #expect(!UndoPhrase.matches(no), "\(no)")
        }
    }
}

@Suite struct PolicyTests {
    let registry = Fixture.registry
    func plan(_ id: String, _ action: DeviceAction) -> ActionPlan {
        ActionPlan(action: action, targets: [registry.device(id: id)!])
    }
    func ctx(_ speaker: SpeakerStanding, mode: AssistantMode = .wakePhrase, person: Bool? = nil,
             media: Bool = false, score: Double = 1) -> PolicyContext {
        PolicyContext(camera: "salon", mode: mode, speaker: speaker, personSeenInRoom: person, mediaPlayingInRoom: media,
                      addressScore: score)
    }
    var engine: PolicyEngine { PolicyEngine(settings: Fixture.settings()) }

    @Test func tiersFromKinds() {
        #expect(plan("light.cuisine", .turnOn).tier == .t0)
        #expect(plan("cover.volets_salon", .close).tier == .t0)
        #expect(plan("media_player.tv_salon", .turnOff).tier == .t0)
        #expect(plan("climate.salon", .setTemperature).tier == .t1)
        #expect(plan("camera.salon", .turnOff).tier == .t1)
        #expect(plan("lock.porte_entree", .unlock).tier == .t2)
        #expect(plan("cover.garage", .open).tier == .t2)
        #expect(plan("alarm_control_panel.maison", .disarm).tier == .t2)
        #expect(plan("lock.porte_entree", .unlock).effect == .destructive)
        #expect(plan("light.cuisine", .query).effect == .readOnly)
    }

    @Test func t0RunsForAnyoneInWakeMode() {
        for s in [SpeakerStanding.unknown, .notIdentified, .maybe, .child(profileID: "c"), .adult(profileID: "a")] {
            #expect(engine.decide(plan("light.cuisine", .turnOn), context: ctx(s)) == .execute)
        }
    }

    @Test func t1NeedsAdultVoice() {
        let p = plan("climate.salon", .setTemperature)
        #expect(engine.decide(p, context: ctx(.adult(profileID: "a"))) == .execute)
        #expect(engine.decide(p, context: ctx(.unknown)) == .refuse(.unknownVoiceForT1))
        #expect(engine.decide(p, context: ctx(.notIdentified)) == .refuse(.unknownVoiceForT1))
        #expect(engine.decide(p, context: ctx(.maybe)) == .refuse(.unknownVoiceForT1))
        #expect(engine.decide(p, context: ctx(.child(profileID: "c"))) == .refuse(.childProfile))
    }

    @Test func t2IsNeverExecutedFromCameraAudio() {
        for id in ["lock.porte_entree", "cover.garage", "alarm_control_panel.maison"] {
            let p = plan(id, id.hasPrefix("lock") ? .unlock : (id.hasPrefix("cover") ? .open : .disarm))
            #expect(engine.decide(p, context: ctx(.adult(profileID: "a"))) == .propose)
            #expect(engine.decide(p, context: ctx(.unknown)) == .refuse(.t2NeedsKnownAdult))
            #expect(engine.decide(p, context: ctx(.child(profileID: "c"))) == .refuse(.childProfile))
            #expect(engine.decide(p, context: ctx(.adult(profileID: "a"), mode: .natural, person: true)) == .refuse(.naturalModeT0Only))
        }
    }

    @Test func maxTierSettingCannotExceedT1() throws {
        var s = Fixture.settings()
        s.maxTierFromCameras = .t2
        let decoded = try JSONDecoder().decode(AssistantSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded.maxTierFromCameras == .t1)
        var off = Fixture.settings()
        off.maxTierFromCameras = .t0
        #expect(PolicyEngine(settings: off).decide(plan("climate.salon", .raise), context: ctx(.adult(profileID: "a")))
                == .refuse(.tierTooHigh))
    }

    @Test func naturalModeRules() {
        let p = plan("light.salon_plafond", .turnOn)
        let known = SpeakerStanding.adult(profileID: "a")
        #expect(engine.decide(p, context: ctx(known, mode: .natural, person: true)) == .execute)
        #expect(engine.decide(p, context: ctx(.child(profileID: "c"), mode: .natural, person: true)) == .execute)
        #expect(engine.decide(p, context: ctx(.unknown, mode: .natural, person: true)) == .refuse(.naturalModeNeedsKnownVoice))
        #expect(engine.decide(p, context: ctx(.maybe, mode: .natural, person: true)) == .refuse(.naturalModeNeedsKnownVoice))
        #expect(engine.decide(p, context: ctx(known, mode: .natural, person: false)) == .refuse(.naturalModeNeedsPerson))
        #expect(engine.decide(p, context: ctx(known, mode: .natural, person: nil)) == .refuse(.naturalModeNeedsPerson))
        #expect(engine.decide(p, context: ctx(known, mode: .natural, person: true, media: true)) == .refuse(.mediaPlaying))
        #expect(engine.decide(p, context: ctx(known, mode: .natural, person: true, score: 0.5)) == .refuse(.notAddressed))
        #expect(engine.decide(plan("climate.salon", .raise), context: ctx(known, mode: .natural, person: true))
                == .refuse(.naturalModeT0Only))
    }
}

@Suite struct RateLimitTests {
    let light = Fixture.registry.device(id: "light.cuisine")!
    let lock = Fixture.registry.device(id: "lock.porte_entree")!

    @Test func duplicatesFromTwoCamerasAreDropped() {
        var limiter = RateLimiter()
        let p = ActionPlan(action: .turnOn, targets: [light])
        let now = Date()
        #expect(limiter.admit(p, at: now) == nil)
        #expect(limiter.admit(p, at: now.addingTimeInterval(1)) == .duplicate)
        #expect(limiter.admit(p, at: now.addingTimeInterval(5)) == nil)
        #expect(limiter.admit(ActionPlan(action: .turnOff, targets: [light]), at: now.addingTimeInterval(5.5)) == nil)
    }

    @Test func t2ProposalsAreCapped() {
        var limiter = RateLimiter()
        let now = Date()
        for i in 0..<3 {
            #expect(limiter.admit(ActionPlan(action: i % 2 == 0 ? .unlock : .lock, targets: [lock]),
                                  at: now.addingTimeInterval(Double(i) * 10)) == nil)
        }
        #expect(limiter.admit(ActionPlan(action: .unlock, targets: [lock]), at: now.addingTimeInterval(40)) == .rateLimited)
        #expect(limiter.admit(ActionPlan(action: .unlock, targets: [lock]), at: now.addingTimeInterval(700)) == nil)
    }

    @Test func t0BurstIsCapped() {
        var limiter = RateLimiter()
        let now = Date()
        var admitted = 0
        // 15 attempts inside one minute (4.1 s apart, so none is a duplicate).
        for i in 0..<15 {
            let p = ActionPlan(action: i % 2 == 0 ? .turnOn : .turnOff, targets: [light])
            if limiter.admit(p, at: now.addingTimeInterval(Double(i) * 4.1)) == nil { admitted += 1 }
        }
        #expect(admitted == 12)
    }
}

@Suite struct AuditTests {
    func plan() -> ActionPlan { ActionPlan(action: .turnOn, targets: [Fixture.registry.device(id: "light.cuisine")!]) }

    @Test func chainVerifiesAndDetectsTampering() async throws {
        let url = tempURL("audit.jsonl")
        let log = try AuditLog(url: url)
        for i in 0..<5 {
            try await log.append(outcome: .executed, camera: "cuisine", mode: .wakePhrase, speaker: "unknown", plan: plan(),
                                 source: .rules, command: "allume la lumiere \(i)", latencyMs: 120)
        }
        try await log.verify()
        try await log.verifyOnDisk()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        // Edit one line on disk: the chain breaks at that entry.
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "allume la lumiere 2", with: "deverrouille la porte")
        try text.write(to: url, atomically: true, encoding: .utf8)
        await #expect(throws: AuditError.brokenChain(seq: 3)) { try await log.verifyOnDisk() }

        // Reopen from disk: still detected.
        let reopened = try AuditLog(url: url)
        await #expect(throws: AuditError.self) { try await reopened.verify() }
    }

    @Test func refusalsNeverKeepWords() async throws {
        let log = try AuditLog(url: tempURL("audit.jsonl"))
        let e = try await log.append(outcome: .refused, camera: "salon", mode: .natural, speaker: "unknown", plan: plan(),
                                     source: .rules, command: "secret words", reason: "naturalModeNeedsKnownVoice")
        #expect(e.command == nil)
    }

    @Test func purgeKeepsChainCheckable() async throws {
        let url = tempURL("audit.jsonl")
        let log = try AuditLog(url: url)
        let old = Date().addingTimeInterval(-40 * 86_400)
        for i in 0..<3 {
            try await log.append(outcome: .executed, camera: "c", mode: .wakePhrase, speaker: "u", plan: plan(), source: .rules,
                                 command: "old \(i)", at: old)
        }
        for i in 0..<2 {
            try await log.append(outcome: .executed, camera: "c", mode: .wakePhrase, speaker: "u", plan: plan(), source: .rules,
                                 command: "new \(i)")
        }
        #expect(try await log.purge(olderThan: Date().addingTimeInterval(-30 * 86_400)) == 3)
        try await log.verify()
        try await log.verifyOnDisk()
        let reopened = try AuditLog(url: url)
        try await reopened.verify()
        #expect(await reopened.all.count == 2)
        // Appending after a purge continues the same chain.
        try await reopened.append(outcome: .executed, camera: "c", mode: .wakePhrase, speaker: "u", plan: plan(), source: .rules, command: "x")
        try await reopened.verifyOnDisk()
    }
}

@Suite struct ProposalTests {
    let key = SymmetricKey(size: .bits256)
    func proposal() -> ActionProposal {
        let plan = ActionPlan(action: .unlock, targets: [Fixture.registry.device(id: "lock.porte_entree")!])
        return ActionProposal(plan: plan, effect: .destructive, createdAt: Date(), expiresAt: Date().addingTimeInterval(30),
                              camera: "entree", speaker: "adult:a")
    }

    @Test func receiptIsSingleUseAndBound() async throws {
        let book = ProposalBook(key: key)
        let p = proposal()
        await book.add(p)
        let receipt = ProposalBook.sign(p, key: key)
        #expect(try await book.redeem(receipt) == p)
        await #expect(throws: ProposalError.alreadyUsed) { try await book.redeem(receipt) }
    }

    @Test func wrongKeyOrOtherProposalIsRefused() async throws {
        let book = ProposalBook(key: key)
        let p = proposal(), q = proposal()
        await book.add(p)
        await book.add(q)
        let forged = ProposalBook.sign(p, key: SymmetricKey(size: .bits256))
        await #expect(throws: ProposalError.badReceipt) { try await book.redeem(forged) }
        // A valid MAC for q presented as p.
        let swapped = ConfirmationReceipt(proposalID: p.id, mac: ProposalBook.sign(q, key: key).mac)
        await #expect(throws: ProposalError.badReceipt) { try await book.redeem(swapped) }
    }

    @Test func expiresOnMonotonicClock() async throws {
        let book = ProposalBook(key: key)
        let p = proposal()
        await book.add(p, lifetime: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(120))
        await #expect(throws: ProposalError.self) { try await book.redeem(ProposalBook.sign(p, key: key)) }
    }
}

@Suite struct ReplyTests {
    let reg = Fixture.registry
    @Test func frenchAgreement() {
        let salon = ActionPlan(action: .turnOn, targets: [reg.device(id: "light.salon_plafond")!, reg.device(id: "light.salon_lampe")!], room: "Salon")
        #expect(ReplyPhrases.done(salon, language: "fr") == "Lumières du salon allumées")
        let one = ActionPlan(action: .turnOn, targets: [reg.device(id: "light.cuisine")!], room: "Cuisine")
        #expect(ReplyPhrases.done(one, language: "fr") == "Lumière de la cuisine allumée")
        let tv = ActionPlan(action: .turnOff, targets: [reg.device(id: "media_player.tv_salon")!], room: "Salon")
        #expect(ReplyPhrases.done(tv, language: "fr") == "Télé du salon éteinte")
        let shutters = ActionPlan(action: .close, targets: [reg.device(id: "cover.volets_salon")!], room: "Salon")
        #expect(ReplyPhrases.done(shutters, language: "fr") == "Volet du salon fermé")
        let heat = ActionPlan(action: .setTemperature, targets: [reg.device(id: "climate.salon")!], value: 21, room: "Salon")
        #expect(ReplyPhrases.done(heat, language: "fr") == "Chauffage du salon réglé à 21°")
        let entree = ActionPlan(action: .unlock, targets: [reg.device(id: "lock.porte_entree")!], room: "Entrée")
        #expect(ReplyPhrases.done(entree, language: "fr") == "Porte de l'entrée déverrouillée")
    }

    @Test func englishAndLanguageGuess() {
        let one = ActionPlan(action: .turnOff, targets: [reg.device(id: "light.cuisine")!], room: "Cuisine")
        #expect(ReplyPhrases.done(one, language: "en") == "Cuisine light off")
        #expect(ReplyPhrases.language(of: "Lumen, turn off the kitchen light") == "en")
        #expect(ReplyPhrases.language(of: "Lumen, allume la lumière du salon") == "fr")
    }
}
