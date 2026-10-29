import AVFoundation
import Foundation
import LumenHearing

/// A short notice for the owner. Never contains what was heard.
public struct AssistantNotice: Sendable, Equatable {
    public enum Kind: String, Sendable { case done, preview, answer, proposal, refused, undone, failed }
    public var kind: Kind
    public var title: String
    public var body: String
    public var camera: String
    public var proposalID: UUID?

    public init(kind: Kind, title: String, body: String, camera: String, proposalID: UUID? = nil) {
        self.kind = kind
        self.title = title
        self.body = body
        self.camera = camera
        self.proposalID = proposalID
    }
}

/// The Hub's existing push channel (owner's iPhone).
public protocol AssistantNotifier: Sendable {
    func notify(_ notice: AssistantNotice) async
}

/// Spoken reply. Mac speakers today (AVSpeechSynthesizer); the camera's own
/// speaker through two-way audio (talkback) later, behind this protocol.
public protocol SpeechOutput: Sendable {
    func speak(_ text: String, language: String, camera: String) async
}

public struct NoSpeechOutput: SpeechOutput {
    public init() {}
    public func speak(_ text: String, language: String, camera: String) async {}
}

@MainActor
public final class SystemSpeechOutput: SpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()
    public nonisolated init() {}
    public nonisolated func speak(_ text: String, language: String, camera: String) async {
        await MainActor.run {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: language == "fr" ? "fr-FR" : "en-US")
            self.synthesizer.speak(utterance)
        }
    }
}

/// Next phase: after acting, a camera checks the device really changed.
public struct VerificationRequest: Sendable, Equatable {
    public var entityID: String
    public var kind: DeviceKind
    public var camera: String?
    /// Expected HA-style state: "on", "off", "open", "closed".
    public var expectedState: String
    public var deadline: Date
}

public protocol ActionVerifier: Sendable {
    func verify(_ request: VerificationRequest) async
}

public struct NoOpVerifier: ActionVerifier {
    public init() {}
    public func verify(_ request: VerificationRequest) async {}
}

public enum VerificationPlanner {
    /// Shutters travel 10–30 s; lights and TVs settle in a few seconds.
    public static func requests(for plan: ActionPlan, registry: DeviceRegistry, now: Date) -> [VerificationRequest] {
        guard !plan.action.isReadOnly else { return [] }
        return plan.targets.compactMap { device in
            let expected: String
            switch plan.action {
            case .turnOn: expected = "on"
            case .turnOff: expected = "off"
            case .open: expected = "open"
            case .close: expected = "closed"
            default: return nil
            }
            let camera = device.verificationCamera ?? registry.room(named: device.room)?.cameras.first
            let delay: TimeInterval = device.kind.isCover ? 45 : 8
            return VerificationRequest(entityID: device.entityID, kind: device.kind, camera: camera, expectedState: expected,
                                       deadline: now.addingTimeInterval(delay))
        }
    }
}

/// Short replies: "Lumière du salon allumée", "Living room light on". No transcript.
public enum ReplyPhrases {
    public static func language(of text: String) -> String {
        let t = " " + KeywordMatcher.normalize(text) + " "
        let english = [" turn ", " the ", " switch ", " open ", " close ", " lights ", " light ", " please ", " on ", " off ",
                       " cancel ", " undo ", " is ", " are ", " set ", " lower ", " raise ", " dim "]
        let french = [" la ", " le ", " les ", " du ", " de ", " allume ", " eteins ", " ferme ", " ouvre ", " annule ",
                      " monte ", " baisse ", " est ", " mets "]
        let en = english.filter { t.contains($0) }.count
        let fr = french.filter { t.contains($0) }.count
        return en > fr ? "en" : "fr"
    }

    struct Noun { let singular: String; let plural: String; let feminine: Bool }

    static func frNoun(_ kind: DeviceKind) -> Noun {
        switch kind {
        case .light: Noun(singular: "Lumière", plural: "Lumières", feminine: true)
        case .outlet: Noun(singular: "Prise", plural: "Prises", feminine: true)
        case .fan: Noun(singular: "Ventilateur", plural: "Ventilateurs", feminine: false)
        case .tv: Noun(singular: "Télé", plural: "Télés", feminine: true)
        case .media: Noun(singular: "Musique", plural: "Enceintes", feminine: true)
        case .shutter: Noun(singular: "Volet", plural: "Volets", feminine: false)
        case .scene: Noun(singular: "Scène", plural: "Scènes", feminine: true)
        case .thermostat: Noun(singular: "Chauffage", plural: "Chauffages", feminine: false)
        case .cameraPrivacy: Noun(singular: "Caméra", plural: "Caméras", feminine: true)
        case .garageDoor: Noun(singular: "Garage", plural: "Garages", feminine: false)
        case .lock: Noun(singular: "Porte", plural: "Portes", feminine: true)
        case .alarm: Noun(singular: "Alarme", plural: "Alarmes", feminine: true)
        case .sensor: Noun(singular: "Capteur", plural: "Capteurs", feminine: false)
        }
    }

    static func enNoun(_ kind: DeviceKind, plural: Bool) -> String {
        let base: String = switch kind {
        case .light: "light"
        case .outlet: "plug"
        case .fan: "fan"
        case .tv: "TV"
        case .media: "speaker"
        case .shutter: "shutter"
        case .scene: "scene"
        case .thermostat: "heating"
        case .cameraPrivacy: "camera"
        case .garageDoor: "garage"
        case .lock: "door"
        case .alarm: "alarm"
        case .sensor: "sensor"
        }
        return plural && kind != .thermostat ? base + "s" : base
    }

    static let masculineRooms: Set<String> = ["salon", "bureau", "couloir", "garage", "sejour", "hall", "grenier", "sous sol",
                                              "jardin", "dressing", "cellier", "palier", "living", "studio"]

    /// "du salon", "de la cuisine", "de l'entrée".
    static func frOfRoom(_ room: String) -> String {
        let lower = room.lowercased()
        let key = KeywordMatcher.normalize(room)
        if let first = key.first, "aeiouyh".contains(first) { return "de l'\(lower)" }
        return masculineRooms.contains(key) ? "du \(lower)" : "de la \(lower)"
    }

    static func frParticiple(_ action: DeviceAction) -> String? {
        switch action {
        case .turnOn: "allumé"
        case .turnOff: "éteint"
        case .open: "ouvert"
        case .close: "fermé"
        case .stop: "arrêté"
        case .raise: "monté"
        case .lower: "baissé"
        case .setTemperature: "réglé"
        case .lock: "verrouillé"
        case .unlock: "déverrouillé"
        case .arm: "activé"
        case .disarm: "désactivé"
        case .query: nil
        }
    }

    static func agree(_ participle: String, feminine: Bool, plural: Bool) -> String {
        var p = participle
        // "éteint" → "éteinte", "éteints".
        if feminine { p += "e" }
        if plural { p += "s" }
        return p
    }

    public static func done(_ plan: ActionPlan, language: String) -> String {
        let kind = plan.targets.first?.kind ?? .light
        let plural = plan.targets.count > 1
        let single = plan.targets.count == 1 ? plan.targets.first : nil
        if language == "en" {
            let what: String
            if let single, plan.room == nil { what = single.name } else {
                what = [plan.room, enNoun(kind, plural: plural)].compactMap { $0 }.joined(separator: " ")
            }
            let verb: String = switch plan.action {
            case .turnOn: "on"
            case .turnOff: "off"
            case .open: "open"
            case .close: "closed"
            case .stop: "stopped"
            case .raise: "up"
            case .lower: "down"
            case .setTemperature: "set to \(format(plan.value))°"
            case .lock: "locked"
            case .unlock: "unlocked"
            case .arm: "armed"
            case .disarm: "disarmed"
            case .query: ""
            }
            return capitalized("\(what) \(verb)")
        }
        let noun = frNoun(kind)
        let head = plural ? noun.plural : noun.singular
        let room = plan.room.map { " " + frOfRoom($0) } ?? ""
        if kind == .thermostat, plan.action == .setTemperature { return "Chauffage\(room) réglé à \(format(plan.value))°" }
        guard let participle = frParticiple(plan.action) else { return head + room }
        return "\(head)\(room) \(agree(participle, feminine: noun.feminine, plural: plural))"
    }

    public static func answer(_ plan: ActionPlan, states: [String: HAEntity], language: String) -> String {
        let parts = plan.targets.map { device -> String in
            let state = states[device.entityID]?.state ?? "unknown"
            if language == "en" { return "\(device.name): \(state)" }
            let fr: String = switch state {
            case "on": "allumé"
            case "off": "éteint"
            case "open": "ouvert"
            case "closed": "fermé"
            case "playing": "en lecture"
            case "unavailable", "unknown": "inconnu"
            default: state
            }
            return "\(device.name) : \(fr)"
        }
        return parts.joined(separator: ", ")
    }

    public static func proposal(_ plan: ActionPlan, language: String) -> (title: String, body: String) {
        let what = done(plan, language: language)
        return language == "en"
            ? ("Confirm on iPhone", "\(what)? Confirm with Face ID within 30 s.")
            : ("Confirmer sur l’iPhone", "\(what) ? Confirmez avec Face ID sous 30 s.")
    }

    public static func undone(language: String) -> String { language == "en" ? "Cancelled" : "Annulé" }
    public static func preview(_ plan: ActionPlan, language: String) -> String {
        (language == "en" ? "Preview: " : "Aperçu : ") + done(plan, language: language)
    }

    static func format(_ value: Double?) -> String {
        guard let value else { return "?" }
        return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}
