#if LUMEN_HUB && DEBUG
import AppKit
import CryptoKit
import LumenHearing
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

    // MARK: - Showing and capture handshake

    @MainActor
    private func show(_ name: String, section: MainWindow.Section, scrollToEnd: Bool = false) async throws {
        UserDefaults.standard.set(section.rawValue, forKey: Self.sectionKey)
        try await show(name, root: MainWindow(state: BridgeState(), coordinator: nil,
                                              onApplyConnection: { _, _, _, _ in },
                                              onToggleHAP: { _ in },
                                              onToggleHomebridge: { _ in },
                                              onSendTestEvent: {}),
                       scrollToEnd: scrollToEnd)
    }

    @MainActor
    private func show<V: View>(_ name: String, root: V, scrollToEnd: Bool = false) async throws {
        let scheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let hosting = NSHostingView(rootView: root.environment(\.colorScheme, scheme))
        hosting.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.title = MainWindow.appName
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(Self.size)
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
        if scrollToEnd {
            Self.scrollViews(in: hosting).forEach { scroll in
                if let doc = scroll.documentView {
                    doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? doc.bounds.height : 0))
                }
            }
            try await settle(0.6)
        }
        // Key again right before the capture: an inactive window draws grey controls.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await settle(0.4)
        // Sheets and dialogs are their own windows: capture that one instead.
        let target = window.attachedSheet ?? window
        let request = dir.appendingPathComponent("req/\(lang)-\(name).id")
        let output = dir.appendingPathComponent("out/\(lang)-\(name).png")
        try? FileManager.default.removeItem(at: output)
        try "\(target.windowNumber)".write(to: request, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(45)
        while !FileManager.default.fileExists(atPath: output.path), Date() < deadline {
            try await settle(0.3)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "no capture for \(name)")
        try await settle(0.3) // let the capture finish writing
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
