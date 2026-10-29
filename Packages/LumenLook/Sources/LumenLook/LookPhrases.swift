import Foundation

/// Short owner-facing lines, FR and EN. Text only: the push never carries the picture.
/// "Volets fermés — vérifié sur la caméra Salon"
/// "Commande envoyée, je ne vois pas les volets (nuit)"
public enum LookPhrases {
    public static func message(for outcome: LookOutcome, kind: LookDeviceKind, expected: LookState, camera: String,
                               source: LookSource, retried: Bool, language: String,
                               commandSent: Bool = true) -> String {
        let cam = cameraName(camera)
        let fr = language != "en"
        switch outcome {
        case .confirmed:
            return fr ? "\(frNoun(kind).capitalizedFirst) \(frAdjective(expected, kind)) — vérifié sur la caméra \(cam)"
                      : "\(enNoun(kind).capitalizedFirst) \(expected.rawValue) — checked on the \(cam) camera"
        case .contradicted(let observed):
            if source == .device {
                return fr ? "\(frNoun(kind).capitalizedFirst) : l'appareil indique toujours « \(frAdjective(observed, kind)) »"
                    + (retried ? ", j'ai réessayé une fois" : "")
                          : "\(enNoun(kind).capitalizedFirst): the device still reports \(observed.rawValue)"
                    + (retried ? ", I tried again once" : "")
            }
            return fr ? "\(frNoun(kind).capitalizedFirst) \(frSeem(kind)) toujours \(frAdjective(observed, kind)) — \(frSeen(kind)) sur la caméra \(cam)"
                + (retried ? ", j'ai réessayé une fois" : "")
                      : "\(enNoun(kind).capitalizedFirst) still \(enSeem(kind)) \(observed.rawValue) — seen on the \(cam) camera"
                + (retried ? ", I tried again once" : "")
        case .unknown(let reason):
            if !commandSent {
                return fr ? "Je ne vois pas \(frArticleNoun(kind)) (\(frReason(reason)))"
                          : "I can't see \(enArticleNoun(kind)) (\(enReason(reason)))"
            }
            return fr ? "Commande envoyée, je ne vois pas \(frArticleNoun(kind)) (\(frReason(reason)))"
                      : "Command sent, I can't see \(enArticleNoun(kind)) (\(enReason(reason)))"
        }
    }

    public static func cameraName(_ id: String) -> String {
        id.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: French

    /// Noun, gender, number.
    static func frNoun(_ kind: LookDeviceKind) -> String {
        switch kind {
        case .light: "lumière"
        case .tv: "télé"
        case .shutter: "volets"
        case .door: "porte"
        }
    }

    static func frArticleNoun(_ kind: LookDeviceKind) -> String {
        kind == .shutter ? "les volets" : "la " + frNoun(kind)
    }

    static func frSeem(_ kind: LookDeviceKind) -> String { kind == .shutter ? "semblent" : "semble" }
    /// "vue" (lumière, télé, porte), "vus" (volets).
    static func frSeen(_ kind: LookDeviceKind) -> String { kind == .shutter ? "vus" : "vue" }

    static func frAdjective(_ state: LookState, _ kind: LookDeviceKind) -> String {
        let plural = kind == .shutter
        // lumière, télé, porte: feminine; volets: masculine plural.
        switch state {
        case .on: return plural ? "allumés" : "allumée"
        case .off: return plural ? "éteints" : "éteinte"
        case .open: return plural ? "ouverts" : "ouverte"
        case .closed: return plural ? "fermés" : "fermée"
        }
    }

    public static func frReason(_ r: UnknownReason) -> String {
        switch r {
        case .night: "nuit"
        case .tooDark: "trop sombre"
        case .privacyMode: "caméra en mode privé"
        case .cameraOffline: "caméra hors ligne"
        case .occluded: "quelque chose est devant"
        case .cameraMoved: "la caméra a bougé, redessinez la zone"
        case .staleFrame: "pas d'image récente"
        case .unsure: "pas sûr"
        case .noArea: "aucune zone dessinée"
        }
    }

    // MARK: English

    static func enNoun(_ kind: LookDeviceKind) -> String {
        switch kind {
        case .light: "light"
        case .tv: "TV"
        case .shutter: "shutters"
        case .door: "door"
        }
    }

    static func enArticleNoun(_ kind: LookDeviceKind) -> String { "the " + enNoun(kind) }
    static func enSeem(_ kind: LookDeviceKind) -> String { kind == .shutter ? "look" : "looks" }

    public static func enReason(_ r: UnknownReason) -> String {
        switch r {
        case .night: "night"
        case .tooDark: "too dark"
        case .privacyMode: "camera in privacy mode"
        case .cameraOffline: "camera offline"
        case .occluded: "something is in the way"
        case .cameraMoved: "the camera moved, redraw the area"
        case .staleFrame: "no recent picture"
        case .unsure: "not sure"
        case .noArea: "no area drawn"
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
