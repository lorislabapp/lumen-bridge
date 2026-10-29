#if LUMEN_HUB && DEBUG
import AppKit
import CryptoKit
import LumenAssistant
import LumenHearing
import LumenLook
import SwiftUI
import XCTest
@testable import Lumen_Bridge

/// Lumen Hub · transcription and voice screens, from the real SwiftUI panes
/// with synthetic fixture data only (fictional names, made-up sentences, no
/// audio). Stores live in a throwaway folder; the voice store is sealed with
/// an in-memory key; nothing reaches Frigate, the Keychain or saved settings.
///
/// Opt-in. Each screen stays on screen until an external capture writes
/// `<dir>/out/<name>.png` (see Scripts/capture-hub-screens.sh):
///   TEST_RUNNER_LUMEN_HUB_SCREENS_DIR=<dir> TEST_RUNNER_LUMEN_HUB_INTERNAL_PRO=1 \
///   xcodebuild test -scheme LumenHub -configuration Debug \
///     -only-testing:LumenHubTests/HubScreensTests -testLanguage fr -testRegion FR
final class HubScreensTests: XCTestCase {
    private static let size = NSSize(width: 1100, height: 760)
    private static let sectionKey = "lumenbridge.mainwindow.section"
    private var savedSection: Any?
    private var dir: URL!
    private var appearance: NSAppearance.Name = .darkAqua

    override func setUpWithError() throws {
        let raw = ProcessInfo.processInfo.environment["LUMEN_HUB_SCREENS_DIR"] ?? ""
        try XCTSkipIf(raw.isEmpty, "Hub screens are opt-in (TEST_RUNNER_LUMEN_HUB_SCREENS_DIR).")
        dir = URL(fileURLWithPath: raw, isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("req"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("out"), withIntermediateDirectories: true)
        savedSection = UserDefaults.standard.object(forKey: Self.sectionKey)
    }

    override func tearDown() {
        if let savedSection {
            UserDefaults.standard.set(savedSection, forKey: Self.sectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.sectionKey)
        }
        super.tearDown()
    }

    private var lang: String { Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en" }

    // MARK: - Screens

    @MainActor
    func testScreens() async throws {
        let f = try await Fixture.make(in: dir.appendingPathComponent("data-\(lang)", isDirectory: true))
        let hearing = HearingService.shared
        let voices = VoiceService.shared

        // Pro not confirmed yet: the banner, transcription off.
        await f.install(hearing: f.offSettings, voices: VoiceSettings())
        try await show("01-transcription-off-no-pro", section: .transcription)

        await HubProStatus.shared.refresh() // LUMEN_HUB_INTERNAL_PRO=1 → internal override
        try await show("02-transcription-off", section: .transcription)

        await f.install(hearing: f.onSettings, voices: f.voiceSettings)
        try await show("03-transcription-on", section: .transcription)
        try await show("04-transcription-on-bottom", section: .transcription, scrollToEnd: true)
        try await show("05-consent-sheet", root: HearingSettingsView(service: hearing, consentFor: "office"))

        var staff = f.onSettings
        staff.staffPresent = true
        await f.install(hearing: staff, voices: f.voiceSettings)
        try await show("06-staff-present", section: .transcription)

        await f.install(hearing: f.onSettings, voices: f.voiceSettings)
        try await show("07-transcripts", section: .transcripts)
        try await show("08-transcripts-search", root: TranscriptsView(service: hearing, query: f.searchWord))

        try await show("09-voices", section: .voices)
        try await show("10-voices-bottom", section: .voices, scrollToEnd: true)
        try await show("11-voice-consent-sheet", root: VoicesView(service: voices, hearing: hearing,
                                                                 presenting: .consent(.init(name: "Sam"))))
        let camille = try XCTUnwrap(voices.profiles.first { $0.name == "Camille" })
        try await show("12-teach-from-clips", root: VoicesView(service: voices, hearing: hearing, presenting: .teach(camille)))
        try await show("13-forget-dialog", root: VoicesView(service: voices, hearing: hearing, presenting: .forget(camille)))

        var off = f.voiceSettings
        off.identificationEnabled = false
        await f.install(hearing: f.onSettings, voices: off)
        try await show("14-voices-names-off", section: .voices)

        appearance = .aqua
        await f.install(hearing: f.onSettings, voices: f.voiceSettings)
        try await show("15-light-transcription-on", section: .transcription)
        try await show("16-light-transcripts", section: .transcripts)
        try await show("17-light-voices", section: .voices)
    }

    /// Assistant pane: fake Home Assistant address, no token in the Keychain
    /// (the "saved" state is faked), made-up devices and rooms, one pending T2
    /// confirmation, a few log lines, preview-only on. Nothing listens.
    @MainActor
    func testAssistantScreens() async throws {
        let f = try await Fixture.make(in: dir.appendingPathComponent("asst-\(lang)", isDirectory: true))
        await f.install(hearing: f.onSettings, voices: f.voiceSettings)
        await HubProStatus.shared.refresh()
        let a = try await AssistantFixture.make(in: dir.appendingPathComponent("asst-\(lang)", isDirectory: true))

        for look in [NSAppearance.Name.darkAqua, .aqua] {
            appearance = look
            let tag = look == .darkAqua ? "dark" : "light"
            await a.install()
            try await show("assistant-\(tag)-1-top", section: .assistant)
            await a.install()
            try await show("assistant-\(tag)-2-home-assistant", section: .assistant, scroll: 0.3)
            await a.install()
            try await show("assistant-\(tag)-3-rooms", section: .assistant, scroll: 0.62)
            await a.install()
            try await show("assistant-\(tag)-4-log", section: .assistant, scroll: 1)
        }
    }

    /// Look ("Check on camera"): areas on a drawn living-room snapshot, made-up
    /// results with cropped proof pictures. No Frigate, no Home Assistant, no
    /// vision server: the store is the test host's throwaway folder.
    @MainActor
    func testLookScreens() async throws {
        let f = try await Fixture.make(in: dir.appendingPathComponent("look-\(lang)", isDirectory: true))
        await f.install(hearing: f.onSettings, voices: f.voiceSettings)
        await HubProStatus.shared.refresh()
        let a = try await AssistantFixture.make(in: dir.appendingPathComponent("look-\(lang)", isDirectory: true))
        let look = LookFixture(assistant: a)

        for appearanceName in [NSAppearance.Name.darkAqua, .aqua] {
            appearance = appearanceName
            let tag = appearanceName == .darkAqua ? "dark" : "light"
            await a.install()
            await look.install()
            try await show("look-\(tag)-1-section", section: .assistant, scroll: LookFixture.sectionScroll)
            await a.install()
            await look.install()
            try await show("look-\(tag)-2-vision", section: .assistant, scroll: LookFixture.visionScroll)
            await look.install()
            try await show("look-\(tag)-3-editor", root: LookAreaEditor(look: .shared, device: a.shutters, close: {}),
                           size: LookFixture.editorSize)
            await look.install()
            try await show("look-\(tag)-4-editor-new", root: LookAreaEditor(look: .shared, device: a.kitchen, close: {}),
                           size: LookFixture.editorSize)
        }
    }

    // MARK: - Showing and capture handshake

    @MainActor
    private func show(_ name: String, section: MainWindow.Section, scrollToEnd: Bool = false,
                      scroll: CGFloat? = nil) async throws {
        UserDefaults.standard.set(section.rawValue, forKey: Self.sectionKey)
        try await show(name, root: MainWindow(state: BridgeState(), coordinator: nil,
                                              onApplyConnection: { _, _, _, _ in },
                                              onToggleHAP: { _ in },
                                              onToggleHomebridge: { _ in },
                                              onSendTestEvent: {}),
                       scroll: scroll ?? (scrollToEnd ? 1 : nil))
    }

    @MainActor
    private func show<V: View>(_ name: String, root: V, scrollToEnd: Bool = false, scroll: CGFloat? = nil,
                               size: NSSize = HubScreensTests.size) async throws {
        let fraction = scroll ?? (scrollToEnd ? 1 : nil)
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let hosting = NSHostingView(rootView: root.environment(\.colorScheme, scheme))
        hosting.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.title = MainWindow.appName
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(size)
        window.center()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        defer {
            window.attachedSheet.map { window.endSheet($0) }
            window.close()
        }
        try await settle(2.0)
        if let fraction {
            Self.scrollViews(in: hosting).forEach { scroll in
                if let doc = scroll.documentView {
                    let travel = max(0, doc.bounds.height - scroll.contentView.bounds.height)
                    let y = doc.isFlipped ? travel * fraction : travel * (1 - fraction)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            try await settle(0.6)
        }
        // Key again right before the capture: an inactive window draws grey controls.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await settle(0.4)
        for _ in 0..<20 where !(NSApp.isActive && (window.attachedSheet ?? window).isKeyWindow) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await settle(0.3)
        }
        try await settle(0.3) // let controls redraw in the active style
        // Sheets and dialogs are their own windows: capture that one instead.
        let target = window.attachedSheet ?? window
        let request = dir.appendingPathComponent("req/\(lang)-\(name).id")
        let output = dir.appendingPathComponent("out/\(lang)-\(name).png")
        // The Mac is shared: another app can take the front between frames.
        // A capture of an inactive window (grey close button) is taken again.
        for attempt in 1...5 {
            try? FileManager.default.removeItem(at: output)
            try "\(target.windowNumber)".write(to: request, atomically: true, encoding: .utf8)
            let deadline = Date().addingTimeInterval(45)
            while !FileManager.default.fileExists(atPath: output.path), Date() < deadline {
                try await settle(0.3)
            }
            try await settle(0.3) // let the capture finish writing
            if target !== window || Self.looksActive(output, width: size.width) || attempt == 5 { break }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await settle(0.8)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "no capture for \(name)")
    }

    /// Red close button = the window was key when captured.
    private static func looksActive(_ png: URL, width: CGFloat = size.width) -> Bool {
        guard let data = try? Data(contentsOf: png), let rep = NSBitmapImageRep(data: data) else { return true }
        let scale = CGFloat(rep.pixelsWide) / width
        guard let c = rep.colorAt(x: Int(26 * scale), y: Int(26 * scale))?.usingColorSpace(.sRGB) else { return true }
        return c.redComponent - c.greenComponent > 0.2
    }

    @MainActor
    private func settle(_ seconds: Double) async throws {
        // Suspending the main actor lets the main run loop lay out and draw.
        try await Task.sleep(for: .seconds(seconds))
    }

    @MainActor
    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let s = view as? NSScrollView { out.append(s) }
        for sub in view.subviews { out += scrollViews(in: sub) }
        return out
    }
}

// MARK: - Synthetic fixture

/// Fictional household: Camille (adult), Léo (child), one unknown voice that
/// keeps appearing with the face "Alex", and the TV. Sentences are made up.
private struct Fixture {
    let transcripts: TranscriptStore
    let voices: VoiceStore
    let searchWord: String

    var offSettings: HearingSettings {
        var s = onSettings
        s.enabled = false
        return s
    }

    var onSettings: HearingSettings {
        var s = HearingSettings()
        s.enabled = true
        let consent = Date().addingTimeInterval(-9 * 86_400)
        try? s.grantConsent(camera: "living_room", placement: .indoor, at: consent)
        try? s.grantConsent(camera: "kitchen", placement: .indoor, at: consent)
        s.setPlacement(.outdoor, camera: "garden")
        s.setPlacement(.street, camera: "front_door")
        s.setKeywords(Self.fr ? ["au secours", "incendie", "colis"] : ["help", "fire", "parcel"])
        s.setRetention(days: 14)
        return s
    }

    var voiceSettings: VoiceSettings {
        var v = VoiceSettings()
        v.diarizationEnabled = true
        v.identificationEnabled = true
        return v
    }

    static let cameras = ["living_room", "kitchen", "office", "garden", "front_door"]
    static var fr: Bool { Locale.preferredLanguages.first?.hasPrefix("fr") ?? false }

    @MainActor
    func install(hearing: HearingSettings, voices settings: VoiceSettings) async {
        var queue = HearingPipeline.Snapshot()
        queue.transcribed = 42
        queue.lastRealTimeFactor = 0.0105
        queue.lastEngine = .parakeetV3
        await HearingService.shared.installScreenFixture(settings: hearing, cameras: Self.cameras, store: transcripts,
                                                          parakeet: .ready, apple: .notDownloaded, queue: queue)
        await VoiceService.shared.installScreenFixture(settings: settings, store: voices, modelState: .ready)
    }

    static func make(in root: URL) async throws -> Fixture {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transcripts = try TranscriptStore(url: root.appendingPathComponent("transcripts.sqlite"))
        let voices = try VoiceStore(url: root.appendingPathComponent("voices.sqlite"),
                                    sealer: AESGCMVoiceSealer(key: SymmetricKey(size: .bits256)))

        let camille = try await voices.addProfile(name: "Camille", faceName: "camille", isChild: false,
                                                  consent: VoiceConsent(acceptedAt: Date().addingTimeInterval(-6 * 86_400),
                                                                        language: fr ? "fr" : "en"))
        let leo = try await voices.addProfile(name: "Léo", isChild: true,
                                              consent: VoiceConsent(acceptedAt: Date().addingTimeInterval(-200 * 86_400),
                                                                    language: "fr"))
        let v = { (seed: Float) in VoiceVector((0..<16).map { sin(Float($0) * seed + seed) })! }
        try await voices.addEmbeddings(profileID: camille.id, (0..<4).map {
            .init(vector: v(1.1 + Float($0) * 0.01), camera: "living_room", source: "enrol", speechSeconds: 4)
        }, at: Date().addingTimeInterval(-6 * 86_400))
        try await voices.addEmbeddings(profileID: leo.id, (0..<3).map {
            .init(vector: v(2.3 + Float($0) * 0.01), camera: "kitchen", source: "enrol", speechSeconds: 3)
        }, at: Date().addingTimeInterval(-150 * 86_400))
        let alex = try await voices.fileUnknown(v(3.7), speechSeconds: 5, camera: "kitchen", eventID: "fx-4",
                                                speaker: "S2", threshold: 0.9, at: Date().addingTimeInterval(-3600))
        for i in 0..<2 { try await voices.addFaceEvidence(clusterID: alex.id, face: "Alex", eventID: "fx-face-\(i)") }
        let tv = try await voices.fileUnknown(v(5.9), speechSeconds: 12, camera: "living_room", eventID: "fx-6",
                                              speaker: "S2", threshold: 0.9, at: Date().addingTimeInterval(-2 * 86_400))
        try await voices.setIgnored(clusterID: tv.id, true) // "this is the TV"

        let lines: [(camera: String, ago: Double, lang: String, engine: EngineKind,
                     segs: [(String, String)], who: [String: SpeakerAssignment])] = fr ? [
            ("kitchen", 600, "fr", .parakeetV3,
             [("S1", "Tu peux sortir le gratin du four dans dix minutes ?"), ("S2", "Oui, et je mets la table après.")],
             ["S1": .init(speaker: "S1", band: .match, profileID: camille.id, score: 0.82),
              "S2": .init(speaker: "S2", band: .unknown, clusterID: alex.id, score: 0.41)]),
            ("living_room", 3_400, "fr", .parakeetV3,
             [("S1", "Le colis est arrivé, je l’ai posé près de l’entrée."), ("S2", "Merci, c’est le livre pour l’école.")],
             ["S1": .init(speaker: "S1", band: .match, profileID: camille.id, score: 0.79),
              "S2": .init(speaker: "S2", band: .maybe, profileID: leo.id, score: 0.58)]),
            ("living_room", 26_000, "fr", .appleSpeech,
             [("S1", "N’oublie pas ton cours de piano demain à dix-sept heures.")],
             ["S1": .init(speaker: "S1", band: .match, profileID: camille.id, score: 0.85)]),
            ("kitchen", 90_000, "en", .parakeetV3,
             [("S1", "Can you check whether the parcel tracking says Thursday?")],
             ["S1": .init(speaker: "S1", band: .unknown, clusterID: alex.id, score: 0.44)]),
            ("living_room", 170_000, "fr", .parakeetV3,
             [("S1", "Et voici la météo de demain : du soleil sur toute la région."), ("S2", "Tu peux baisser le son ?")],
             ["S1": .init(speaker: "S1", band: .ignored, clusterID: tv.id),
              "S2": .init(speaker: "S2", band: .match, profileID: camille.id, score: 0.77)]),
            ("kitchen", 260_000, "fr", .parakeetV3, [("S1", "Il reste du pain pour le petit-déjeuner ?")], [:]),
        ] : [
            ("kitchen", 600, "en", .parakeetV3,
             [("S1", "Can you take the lasagne out of the oven in ten minutes?"), ("S2", "Sure, then I’ll set the table.")],
             ["S1": .init(speaker: "S1", band: .match, profileID: camille.id, score: 0.82),
              "S2": .init(speaker: "S2", band: .unknown, clusterID: alex.id, score: 0.41)]),
            ("living_room", 3_400, "en", .parakeetV3,
             [("S1", "The parcel came, I left it by the front door."), ("S2", "Thanks, it’s the book for school.")],
             ["S1": .init(speaker: "S1", band: .match, profileID: camille.id, score: 0.79),
              "S2": .init(speaker: "S2", band: .maybe, profileID: leo.id, score: 0.58)]),
            ("living_room", 26_000, "en", .appleSpeech,
             [("S1", "Don’t forget your piano lesson tomorrow at five.")],
             ["S1": .init(speaker: "S1", band: .match, profileID: camille.id, score: 0.85)]),
            ("kitchen", 90_000, "fr", .parakeetV3,
             [("S1", "Tu peux regarder si le suivi du colis dit jeudi ?")],
             ["S1": .init(speaker: "S1", band: .unknown, clusterID: alex.id, score: 0.44)]),
            ("living_room", 170_000, "en", .parakeetV3,
             [("S1", "And here is tomorrow’s weather: sunshine across the region."), ("S2", "Can you turn it down?")],
             ["S1": .init(speaker: "S1", band: .ignored, clusterID: tv.id),
              "S2": .init(speaker: "S2", band: .match, profileID: camille.id, score: 0.77)]),
            ("kitchen", 260_000, "en", .parakeetV3, [("S1", "Is there any bread left for breakfast?")], [:]),
        ]

        for (i, line) in lines.enumerated() {
            let start = Date().addingTimeInterval(-line.ago)
            var t = 0.4
            var segments: [TranscriptSegment] = []
            var turns: [SpeakerTurn] = []
            for (speaker, text) in line.segs {
                let d = max(2.2, Double(text.count) / 14)
                segments.append(TranscriptSegment(start: t, end: t + d, text: text, confidence: 0.93,
                                                  speaker: line.who.isEmpty ? nil : speaker))
                turns.append(SpeakerTurn(speaker: speaker, start: t, end: t + d))
                t += d + 0.5
            }
            let event = SpeechEvent(id: "fx-\(i + 1)", camera: line.camera, start: start, end: start.addingTimeInterval(t))
            let transcript = EngineTranscript(text: line.segs.map(\.1).joined(separator: " "), segments: segments,
                                              language: line.lang, engine: line.engine,
                                              audioSeconds: t, processingSeconds: t * 0.0105)
            _ = try await transcripts.insert(.init(event: event, transcript: transcript, created: start))
            if !line.who.isEmpty {
                try await voices.recordEvent(eventID: event.id, camera: line.camera, eventStart: start, turns: turns,
                                             assignments: Array(line.who.values), at: start)
            }
        }
        return Fixture(transcripts: transcripts, voices: voices, searchWord: fr ? "colis" : "parcel")
    }
}
#endif

#if LUMEN_HUB && DEBUG
/// Made-up household devices for the Assistant pane. The address is a
/// reserved test domain; the token is never written to the Keychain.
@MainActor
private struct AssistantFixture {
    let log: AuditLog
    let registry: DeviceRegistry
    let lock: Device
    let living: Device
    let kitchen: Device
    let tv: Device
    let shutters: Device
    static var fr: Bool { Locale.preferredLanguages.first?.hasPrefix("fr") ?? false }

    static func make(in root: URL) async throws -> AssistantFixture {
        let fr = Self.fr
        let livingRoom = fr ? "Salon" : "Living room", kitchenRoom = fr ? "Cuisine" : "Kitchen"
        let living = Device(entityID: "light.salon_plafonnier", name: fr ? "Plafonnier du salon" : "Living room ceiling light",
                            kind: .light, room: livingRoom)
        let kitchen = Device(entityID: "light.cuisine", name: fr ? "Lumières de la cuisine" : "Kitchen lights",
                             kind: .light, room: kitchenRoom)
        let tv = Device(entityID: "media_player.salon_tv", name: fr ? "Télé du salon" : "Living room TV", kind: .tv, room: livingRoom)
        let shutters = Device(entityID: "cover.salon_volets", name: fr ? "Volets du salon" : "Living room shutters",
                              kind: .shutter, room: livingRoom)
        let heating = Device(entityID: "climate.maison", name: fr ? "Chauffage" : "Heating", kind: .thermostat)
        let lock = Device(entityID: "lock.porte_entree", name: fr ? "Serrure de l’entrée" : "Front door lock", kind: .lock)
        let coffee = Device(entityID: "switch.cafetiere", name: fr ? "Cafetière" : "Coffee machine", kind: .outlet,
                            room: kitchenRoom, exposed: false)
        let registry = DeviceRegistry(devices: [living, kitchen, tv, shutters, heating, lock, coffee],
                                      rooms: [Room(name: livingRoom, cameras: ["living_room"]),
                                              Room(name: kitchenRoom, cameras: ["kitchen"])])

        let url = root.appendingPathComponent("assistant-audit.jsonl")
        try? FileManager.default.removeItem(at: url)
        let log = try AuditLog(url: url)
        let now = Date()
        let adult = "adult:fixture-camille", child = "child:fixture-leo"
        try await log.append(outcome: .executed, camera: "kitchen", mode: .wakePhrase, speaker: adult,
                             plan: ActionPlan(action: .turnOn, targets: [kitchen]), source: .rules,
                             command: fr ? "lumen allume la cuisine" : "lumen turn on the kitchen lights",
                             reason: "light.turn_on", latencyMs: 212, at: now.addingTimeInterval(-26 * 3600))
        try await log.append(outcome: .refused, camera: "living_room", mode: .wakePhrase, speaker: child,
                             plan: ActionPlan(action: .raise, targets: [heating]), source: .rules, command: nil,
                             reason: RefusalReason.childProfile.rawValue, at: now.addingTimeInterval(-5 * 3600))
        try await log.append(outcome: .answered, camera: "kitchen", mode: .wakePhrase, speaker: adult,
                             plan: ActionPlan(action: .query, targets: [kitchen]), source: .rules,
                             command: fr ? "lumen la lumière de la cuisine est allumée" : "lumen is the kitchen light on",
                             latencyMs: 164, at: now.addingTimeInterval(-3 * 3600))
        let proposal = ActionProposal(plan: ActionPlan(action: .unlock, targets: [lock]), effect: .destructive,
                                      createdAt: now, expiresAt: now.addingTimeInterval(25),
                                      camera: "living_room", speaker: adult)
        try await log.append(outcome: .proposed, camera: "living_room", mode: .wakePhrase, speaker: adult,
                             plan: proposal.plan, source: .rules,
                             command: fr ? "lumen déverrouille la porte" : "lumen unlock the front door",
                             reason: proposal.id.uuidString, at: now.addingTimeInterval(-40))
        try await log.append(outcome: .previewed, camera: "living_room", mode: .wakePhrase, speaker: adult,
                             plan: ActionPlan(action: .turnOn, targets: [living]), source: .llm,
                             command: fr ? "lumen il fait un peu sombre ici" : "lumen it is a bit dark in here",
                             reason: "light.turn_on", latencyMs: 640, at: now.addingTimeInterval(-12))
        return AssistantFixture(log: log, registry: registry, lock: lock, living: living, kitchen: kitchen, tv: tv,
                                shutters: shutters)
    }

    func install() async {
        var s = AssistantSettings()
        s.enabled = true
        s.mode = .wakePhrase
        s.cameras = ["living_room", "kitchen"]
        s.dryRun = true
        s.notifyPhone = true
        s.speakReplies = false
        s.homeAssistantURL = "http://ha.example.test:8123"
        s.llmURL = "http://127.0.0.1:8012"
        s.llmEnabled = true
        let lang = Self.fr ? "fr" : "en"
        // A fresh pending T2 request each time, so it always shows "in 25 seconds".
        let now = Date()
        let book = ProposalBook(key: SymmetricKey(size: .bits256))
        await book.add(ActionProposal(plan: ActionPlan(action: .unlock, targets: [lock]), effect: .destructive,
                                      createdAt: now, expiresAt: now.addingTimeInterval(25),
                                      camera: "living_room", speaker: "adult:fixture-camille"),
                       lifetime: .seconds(3600))
        await AssistantService.shared.installScreenFixture(
            settings: s, registry: registry, log: log, book: book, hasToken: true,
            homeAssistant: .ok(148), llm: .ok(0),
            listening: ["living_room": AL("Listening"), "kitchen": AL("Listening")],
            lastResult: ReplyPhrases.preview(ActionPlan(action: .turnOn, targets: [living], room: living.room), language: lang),
            canUndo: false)
    }
}
#endif

#if LUMEN_HUB && DEBUG
/// Look areas for the made-up living room: shutters (closed, checked), TV
/// (still off after one retry), ceiling light (night, unsure); the kitchen has
/// no area yet. Snapshots are drawn here; proofs are crops of them.
@MainActor
private struct LookFixture {
    let assistant: AssistantFixture
    static let sectionScroll: CGFloat = 0.465
    static let visionScroll: CGFloat = 0.6
    static let editorSize = NSSize(width: 760, height: 640)

    static let shutterArea = LookRect(x: 0.08, y: 0.16, width: 0.25, height: 0.42)
    static let tvArea = LookRect(x: 0.42, y: 0.40, width: 0.26, height: 0.26)
    static let lampArea = LookRect(x: 0.77, y: 0.22, width: 0.11, height: 0.16)

    func install() async {
        let living = LivingRoomScene.image(night: false), kitchen = LivingRoomScene.kitchen()
        let a = assistant
        let fr = AssistantFixture.fr
        let lang = fr ? "fr" : "en"
        let targets = [
            LookTarget(entityID: a.shutters.entityID, name: a.shutters.name, kind: .shutter, camera: "living_room",
                       area: Self.shutterArea, travelSeconds: 25),
            LookTarget(entityID: a.tv.entityID, name: a.tv.name, kind: .tv, camera: "living_room", area: Self.tvArea),
            LookTarget(entityID: a.living.entityID, name: a.living.name, kind: .light, camera: "living_room",
                       area: Self.lampArea, travelSeconds: 2),
        ]
        func timing(_ ms: Double) -> LookTiming { var t = LookTiming(); t.totalMs = ms; return t }
        let now = Date()
        func result(_ t: LookTarget, _ outcome: LookOutcome, expected: LookState, source: LookSource, ms: Double,
                    ago: TimeInterval, retried: Bool = false) -> LookResult {
            LookResult(entityID: t.entityID, camera: t.camera, expected: expected, outcome: outcome, source: source,
                       confidence: 0.9, evidence: "fixture", checkedAt: now.addingTimeInterval(-ago), retried: retried,
                       timing: timing(ms),
                       message: LookPhrases.message(for: outcome, kind: t.kind, expected: expected, camera: t.camera,
                                                    source: source, retried: retried, language: lang))
        }
        let results = [
            result(targets[0], .confirmed, expected: .closed, source: .pixels, ms: 184, ago: 600),
            result(targets[1], .contradicted(observed: .off), expected: .on, source: .visionModel, ms: 2_350, ago: 95,
                   retried: true),
            result(targets[2], .unknown(.night), expected: .on, source: .pixels, ms: 210, ago: 30),
        ]
        let night = LivingRoomScene.image(night: true)
        let proofs: [String: CGImage] = [
            targets[0].entityID: LivingRoomScene.crop(living, Self.shutterArea.expanded(by: 0.15)),
            targets[1].entityID: LivingRoomScene.crop(living, Self.tvArea.expanded(by: 0.15)),
            targets[2].entityID: LivingRoomScene.crop(night, Self.lampArea.expanded(by: 0.3)),
        ].compactMapValues { $0 }
        var prefs = LookService.Prefs()
        prefs.enabled = true
        prefs.useModel = true
        prefs.proofHours = 24
        await LookService.shared.installScreenFixture(prefs: prefs, targets: targets, results: results, proofs: proofs,
                                                      frames: ["living_room": living, "kitchen": kitchen],
                                                      vision: .ok(0))
    }
}

/// A drawn 1280×720 room: window with shutters (left), TV (centre), floor lamp (right).
enum LivingRoomScene {
    static let size = CGSize(width: 1280, height: 720)

    static func image(night: Bool) -> CGImage {
        draw { ctx in
            let grey = night
            // Wall and floor.
            fill(ctx, CGRect(x: 0, y: 0, width: 1280, height: 520), grey ? gray(0.32) : rgb(0.86, 0.82, 0.74))
            fill(ctx, CGRect(x: 0, y: 520, width: 1280, height: 200), grey ? gray(0.22) : rgb(0.55, 0.40, 0.28))
            // Window frame and closed shutter slats.
            fill(ctx, CGRect(x: 92, y: 106, width: 336, height: 316), grey ? gray(0.55) : rgb(0.95, 0.95, 0.93))
            for i in 0..<14 {
                fill(ctx, CGRect(x: 104, y: 118 + CGFloat(i) * 21.6, width: 312, height: 17),
                     grey ? gray(0.42) : rgb(0.62, 0.66, 0.70))
            }
            // TV cabinet and screen (off).
            fill(ctx, CGRect(x: 500, y: 478, width: 420, height: 60), grey ? gray(0.18) : rgb(0.30, 0.22, 0.16))
            fill(ctx, CGRect(x: 545, y: 296, width: 320, height: 176), gray(0.06))
            fill(ctx, CGRect(x: 553, y: 304, width: 304, height: 160), grey ? gray(0.10) : rgb(0.08, 0.09, 0.11))
            // Sofa.
            fill(ctx, CGRect(x: 180, y: 520, width: 300, height: 110), grey ? gray(0.28) : rgb(0.30, 0.42, 0.52))
            // Floor lamp: pole and shade (lit by day, dark at night).
            fill(ctx, CGRect(x: 1053, y: 270, width: 8, height: 290), grey ? gray(0.2) : rgb(0.2, 0.2, 0.2))
            fill(ctx, CGRect(x: 1000, y: 170, width: 114, height: 100), grey ? gray(0.45) : rgb(1.0, 0.88, 0.55))
            fill(ctx, CGRect(x: 1020, y: 552, width: 74, height: 12), grey ? gray(0.2) : rgb(0.2, 0.2, 0.2))
            // Plant.
            fill(ctx, CGRect(x: 930, y: 470, width: 46, height: 60), grey ? gray(0.25) : rgb(0.55, 0.35, 0.25))
            fill(ctx, CGRect(x: 912, y: 390, width: 82, height: 84), grey ? gray(0.30) : rgb(0.25, 0.50, 0.30))
        }
    }

    static func kitchen() -> CGImage {
        draw { ctx in
            fill(ctx, CGRect(x: 0, y: 0, width: 1280, height: 720), rgb(0.90, 0.90, 0.88))
            fill(ctx, CGRect(x: 0, y: 430, width: 1280, height: 290), rgb(0.72, 0.70, 0.66))
            fill(ctx, CGRect(x: 120, y: 330, width: 1040, height: 110), rgb(0.35, 0.45, 0.42))
            fill(ctx, CGRect(x: 120, y: 120, width: 420, height: 150), rgb(0.40, 0.50, 0.47))
            fill(ctx, CGRect(x: 760, y: 60, width: 160, height: 26), rgb(0.98, 0.94, 0.80))
            fill(ctx, CGRect(x: 600, y: 140, width: 260, height: 170), rgb(0.70, 0.84, 0.95))
        }
    }

    static func crop(_ image: CGImage, _ rect: LookRect) -> CGImage? {
        image.cropping(to: rect.clamped.pixels(width: image.width, height: image.height))
    }

    private static func draw(_ body: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Top-left origin, like the camera picture.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        body(ctx)
        return ctx.makeImage()!
    }

    private static func fill(_ ctx: CGContext, _ r: CGRect, _ c: CGColor) {
        ctx.setFillColor(c)
        ctx.fill(r)
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    private static func gray(_ v: CGFloat) -> CGColor { CGColor(srgbRed: v, green: v, blue: v, alpha: 1) }
}
#endif
