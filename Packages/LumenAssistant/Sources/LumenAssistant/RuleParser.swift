import Foundation
import LumenHearing

public enum NotCommandReason: String, Codable, Sendable, Equatable {
    case empty
    case noVerb
    case negation
    /// "il faudrait…", "we should…", "un jour", "tomorrow".
    case hedge
    /// "j'ai allumé…", "did you turn…", "yesterday".
    case pastOrReport
    /// "si…", "quand…", "if…", "when…".
    case conditional
    /// "pourquoi…", "who…": not a house request.
    case openQuestion
    /// "j'allume…", "on éteint ?", "let's…": talking to people.
    case firstPerson
    case unsupportedDevice
}

public enum CommandSource: String, Codable, Sendable { case rules, llm }

public struct ParsedCommand: Sendable, Equatable {
    public var plan: ActionPlan
    /// How sure the parser is that this is a request (0…1).
    public var confidence: Double
    /// The verb is the first thing said (after a polite "tu peux…").
    public var imperative: Bool
    /// A room was spoken, rather than taken from the camera.
    public var explicitRoom: Bool
    public var source: CommandSource
}

public enum ParseResult: Sendable, Equatable {
    case command(ParsedCommand)
    case notACommand(NotCommandReason)
    /// A verb was heard but the target is unclear: try the LLM.
    case unsure(String)

    public var command: ParsedCommand? { if case .command(let c) = self { c } else { nil } }
}

/// Deterministic FR + EN parser for a closed home vocabulary. Runs first, in
/// microseconds; the LLM is only asked when this returns `.unsure`.
public struct RuleParser: Sendable {
    public init() {}

    // MARK: Lexicon

    /// Verb word (normalized) → action. Multi-word verbs are matched first.
    static let phraseVerbs: [(String, DeviceAction)] = [
        ("mets en marche", .turnOn), ("met en marche", .turnOn), ("mets en route", .turnOn),
        ("turn on", .turnOn), ("switch on", .turnOn), ("put on", .turnOn), ("power on", .turnOn),
        ("turn off", .turnOff), ("switch off", .turnOff), ("shut off", .turnOff), ("power off", .turnOff),
        ("turn up", .raise), ("turn down", .lower), ("roll up", .open), ("roll down", .close),
        ("plus fort", .raise), ("moins fort", .lower),
    ]
    static let verbs: [String: DeviceAction] = [
        // FR on
        "allume": .turnOn, "allumes": .turnOn, "allumez": .turnOn, "allumer": .turnOn, "active": .turnOn,
        "activez": .turnOn, "activer": .turnOn, "demarre": .turnOn, "demarrez": .turnOn, "lance": .turnOn,
        "lancez": .turnOn, "branche": .turnOn,
        // FR off
        "eteins": .turnOff, "eteint": .turnOff, "eteignez": .turnOff, "eteindre": .turnOff, "coupe": .turnOff,
        "coupez": .turnOff, "couper": .turnOff, "desactive": .turnOff, "desactivez": .turnOff,
        "arrete": .stop, "arretez": .stop, "stoppe": .stop,
        // FR covers / doors
        "ouvre": .open, "ouvrez": .open, "ouvrir": .open, "leve": .open, "levez": .open, "remonte": .open,
        "ferme": .close, "fermez": .close, "fermer": .close, "descends": .close, "descendez": .close,
        // FR up / down
        "monte": .raise, "montez": .raise, "augmente": .raise, "augmentez": .raise,
        "baisse": .lower, "baissez": .lower, "diminue": .lower, "diminuez": .lower, "tamise": .lower,
        // FR set
        "mets": .setTemperature, "met": .setTemperature, "regle": .setTemperature, "reglez": .setTemperature,
        "passe": .setTemperature, "mettre": .setTemperature, "regler": .setTemperature,
        "baisser": .lower, "monter": .raise, "augmenter": .raise, "diminuer": .lower, "remonter": .open,
        "descendre": .close, "arreter": .stop, "lancer": .turnOn, "desactiver": .turnOff, "tamiser": .lower,
        "verrouiller": .lock, "deverrouiller": .unlock, "demarrer": .turnOn,
        // FR security
        "verrouille": .lock, "verrouillez": .lock, "deverrouille": .unlock, "deverrouillez": .unlock,
        "arme": .arm, "armez": .arm, "desarme": .disarm, "desarmez": .disarm,
        // EN
        "open": .open, "close": .close, "shut": .close, "raise": .raise, "lower": .lower, "dim": .lower,
        "brighten": .raise, "increase": .raise, "decrease": .lower, "stop": .stop, "halt": .stop,
        "activate": .turnOn, "enable": .turnOn, "deactivate": .turnOff, "disable": .turnOff, "start": .turnOn,
        "set": .setTemperature, "lock": .lock, "unlock": .unlock, "arm": .arm, "disarm": .disarm,
        "turn": .turnOn, "switch": .turnOn,
        // "make it brighter"
        "brighter": .raise, "louder": .raise, "warmer": .raise, "dimmer": .lower, "quieter": .lower,
        "darker": .lower, "cooler": .lower,
    ]
    /// Separable English verbs: "turn the light off".
    static let separable: Set<String> = ["turn", "switch", "put", "power", "shut"]

    static let kindWords: [(String, DeviceKind)] = [
        ("porte de garage", .garageDoor), ("porte du garage", .garageDoor), ("garage door", .garageDoor), ("porte d entree", .lock), ("front door", .lock),
        ("air conditioning", .thermostat), ("systeme d alarme", .alarm),
        ("lumieres", .light), ("lumiere", .light), ("lampes", .light), ("lampe", .light), ("plafonnier", .light),
        ("eclairage", .light), ("lustre", .light), ("spots", .light), ("lights", .light), ("light", .light),
        ("lamps", .light), ("lamp", .light),
        ("television", .tv), ("televiseur", .tv), ("tele", .tv), ("tv", .tv), ("telly", .tv),
        ("musique", .media), ("enceinte", .media), ("enceintes", .media), ("radio", .media), ("music", .media),
        ("speaker", .media), ("speakers", .media), ("son", .media), ("volume", .media),
        ("volets", .shutter), ("volet", .shutter), ("stores", .shutter), ("store", .shutter), ("rideaux", .shutter),
        ("rideau", .shutter), ("persiennes", .shutter), ("shutters", .shutter), ("shutter", .shutter),
        ("blinds", .shutter), ("blind", .shutter), ("curtains", .shutter), ("curtain", .shutter),
        ("ventilateur", .fan), ("ventilo", .fan), ("fan", .fan),
        ("prises", .outlet), ("prise", .outlet), ("plug", .outlet), ("socket", .outlet), ("outlet", .outlet),
        ("chauffage", .thermostat), ("thermostat", .thermostat), ("radiateurs", .thermostat), ("radiateur", .thermostat),
        ("climatisation", .thermostat), ("clim", .thermostat), ("heating", .thermostat), ("heater", .thermostat),
        ("temperature", .thermostat),
        ("cameras", .cameraPrivacy), ("camera", .cameraPrivacy),
        // "portail"/"gate" is a different device: only a device named so matches it.
        ("garage", .garageDoor),
        ("serrure", .lock), ("verrou", .lock), ("porte", .lock), ("door", .lock), ("lock", .lock),
        ("alarme", .alarm), ("alarm", .alarm),
    ]

    static let politePrefixes: [String] = [
        "est ce que tu pourrais", "est ce que tu peux", "est ce que vous pouvez", "est ce que tu veux bien",
        "tu pourrais", "pourrais tu", "tu peux", "peux tu", "vous pouvez", "pouvez vous", "tu veux bien",
        "je veux que tu", "j aimerais que tu", "je voudrais que tu", "merci de",
        "can you please", "could you please", "would you please", "can you", "could you", "would you", "will you",
        "i want you to", "i d like you to", "please", "kindly",
    ]
    static let fillers: [String] = ["s il te plait", "s il vous plait", "stp", "svp", "merci", "please", "thanks", "thank you", "maintenant", "now"]

    static let hedges: [String] = [
        "il faudrait", "faudrait", "faudra", "il faut que", "on devrait", "on pourrait", "je devrais", "tu devrais",
        "un jour", "plus tard", "demain", "ce soir", "la semaine prochaine", "a un moment", "peut etre",
        "we should", "you should", "i should", "should", "we could", "someday", "some day", "one day", "maybe",
        "later", "tomorrow", "next week", "i wonder", "remember to", "need to", "have to", "gotta", "going to",
        "gonna", "i ll", "we ll", "i will", "we will", "ought to", "would be nice",
    ]
    static let conditionalStarts: Set<String> = ["si", "quand", "lorsque", "if", "when", "whenever", "once", "avant", "apres", "before", "after"]
    static let openQuestionWords: Set<String> = ["pourquoi", "qui", "comment", "combien", "why", "who", "how", "what", "where", "ou", "quoi", "quel", "quelle"]
    static let pastMarkersEN: Set<String> = ["turned", "switched", "opened", "closed", "locked", "unlocked", "dimmed", "did", "was", "were", "had", "yesterday", "already", "earlier"]
    static let pastMarkersFR: [String] = [
        "j ai", "tu as", "il a", "elle a", "on a", "nous avons", "vous avez", "ils ont", "elles ont", "avait", "avais",
        "a ete", "hier", "deja", "tout a l heure", "as tu", "avez vous", "a t il", "a t elle", "t as", "t avais",
    ]
    static let firstPerson: [String] = ["j allume", "j eteins", "j ouvre", "je ferme", "je monte", "je baisse", "je mets",
                                        "je coupe", "on allume", "on eteint", "on ouvre", "on ferme", "on monte", "on baisse",
                                        "on met", "i turn", "i open", "i close", "we turn", "let s", "lets", "i m turning",
                                        "i am turning", "je vais"]
    static let whole: Set<String> = ["toutes", "tous", "partout", "maison", "all", "everywhere", "every", "house", "whole"]
    static let stateWordsFR: [String: DeviceAction] = [
        "allume": .query, "allumee": .query, "allumees": .query, "allumes": .query, "eteint": .query, "eteinte": .query,
        "eteintes": .query, "eteints": .query, "ouvert": .query, "ouverte": .query, "ouverts": .query, "ouvertes": .query,
        "ferme": .query, "fermee": .query, "fermes": .query, "fermees": .query,
    ]

    // MARK: Parse

    /// `text` is the command part (after the wake phrase). `camera` gives the
    /// default room. Only exposed devices are ever returned.
    public func parse(_ text: String, registry: DeviceRegistry, camera: String?) -> ParseResult {
        var t = " " + KeywordMatcher.normalize(text) + " "
        for filler in Self.fillers { t = t.replacingOccurrences(of: " \(filler) ", with: " ") }
        t = Self.squash(t)
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return .notACommand(.empty) }

        // Politeness makes it a request ("tu peux allumer…", "can you turn…").
        var polite = false
        for prefix in Self.politePrefixes where t.hasPrefix(" \(prefix) ") {
            t = " " + String(t.dropFirst(prefix.count + 2))
            polite = true
            break
        }
        let tokens = t.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return .notACommand(.empty) }

        // Screens: talk about devices that is not a request now.
        if Self.containsAny(t, Self.hedges) { return .notACommand(.hedge) }
        if Self.conditionalStarts.contains(first) { return .notACommand(.conditional) }
        if Self.isNegated(t, tokens: tokens) { return .notACommand(.negation) }
        if Self.containsAny(t, Self.firstPerson) { return .notACommand(.firstPerson) }
        // State questions start with their marker; they are checked before the past/open-question screens.
        let questionStarts = ["is the", "are the", "is my", "are my", "est ce que", "il fait combien", "quelle temperature",
                              "what s the temperature", "what is the temperature", "how warm", "how cold", "combien il fait"]
        if questionStarts.contains(where: { t.hasPrefix(" \($0) ") }),
           let query = queryCommand(t, tokens: tokens, registry: registry, camera: camera) { return query }
        if !tokens.filter(Self.pastMarkersEN.contains).isEmpty || Self.containsAny(t, Self.pastMarkersFR) {
            return .notACommand(.pastOrReport)
        }
        if Self.openQuestionWords.contains(first) { return .notACommand(.openQuestion) }

        // Status question: "est-ce que la lumière du salon est allumée", "is the kitchen light on".
        if let query = queryCommand(t, tokens: tokens, registry: registry, camera: camera) { return query }

        guard let (verbAction, verbIndex, verbText) = Self.findVerb(t, tokens: tokens) else { return .notACommand(.noVerb) }
        var action = verbAction
        // English separable particle: "turn the hall light off".
        if Self.separable.contains(verbText.split(separator: " ").first.map(String.init) ?? "") {
            let after = tokens.dropFirst(verbIndex + 1)
            if verbText.hasSuffix(" off") || after.contains("off") { action = .turnOff }
            else if verbText.hasSuffix(" on") || after.contains("on") { action = .turnOn }
            else if verbText.hasSuffix(" up") || after.contains("up") { action = .raise }
            else if verbText.hasSuffix(" down") || after.contains("down") { action = .lower }
            else if verbText == "shut" { action = .close }
        }
        let imperative = verbIndex <= 1

        // Targets.
        let explicitRoom = Self.findRoom(t, registry: registry)
        // "la lampe du bureau" with no room "bureau": never fall back to the camera's room.
        if explicitRoom == nil, Self.mentionsUnknownPlace(t, registry: registry) { return .unsure(t.trimmingCharacters(in: .whitespaces)) }
        let room = explicitRoom ?? camera.flatMap(registry.room(forCamera:))
        let wantsAll = !Set(tokens).isDisjoint(with: Self.whole)
        var targets: [Device]
        var kind: DeviceKind?
        let spoken = Self.findKind(t)
        if let named = Self.findNamedDevice(t, registry: registry, spokenKind: spoken) {
            targets = [named]
            kind = named.kind
        } else if let spokenKind = spoken {
            kind = spokenKind
            targets = Self.devices(of: spokenKind, room: wantsAll ? nil : room, registry: registry)
            // "monte le son" in the salon: the salon TV before a speaker elsewhere.
            if targets.isEmpty, spokenKind == .media, let room {
                targets = Self.devices(of: .tv, room: room, registry: registry)
            }
            // "allume le plafonnier": narrow to devices whose own name holds the spoken word.
            if targets.count > 1, let word = Self.kindWordSpoken(t), case let named = targets.filter({
                KeywordMatcher.normalize($0.name).split(separator: " ").contains(Substring(word)) }), !named.isEmpty {
                targets = named
            }
            // One of a kind in the whole house: "allume la télé" with one TV.
            if targets.isEmpty, explicitRoom == nil {
                let everywhere = Self.devices(of: spokenKind, room: nil, registry: registry)
                if everywhere.count == 1 || (wantsAll && spokenKind.tier == .t0) { targets = everywhere }
            }
            // "la télé" may be a plain media player.
            if targets.isEmpty, spokenKind == .tv || spokenKind == .media {
                let other: DeviceKind = spokenKind == .tv ? .media : .tv
                targets = Self.devices(of: other, room: room, registry: registry)
            }
        } else {
            return .unsure(t.trimmingCharacters(in: .whitespaces))
        }
        guard let kind, !targets.isEmpty else { return .unsure(t.trimmingCharacters(in: .whitespaces)) }
        // "Tout" never widens beyond T0.
        if wantsAll, kind.tier > .t0, explicitRoom == nil, targets.count > 1 { return .unsure(t.trimmingCharacters(in: .whitespaces)) }

        // Map the verb onto what this kind of device can do.
        guard let mapped = Self.map(action, kind: kind, text: t) else { return .notACommand(.unsupportedDevice) }
        var value: Double?
        if mapped == .setTemperature {
            guard let number = Self.number(in: tokens), (5...35).contains(number) else {
                return .unsure(t.trimmingCharacters(in: .whitespaces))
            }
            value = number
        }
        let confidence = (imperative ? 0.95 : 0.8) * (polite ? 1 : 0.98)
        let plan = ActionPlan(action: mapped, targets: targets, value: value, room: room?.name)
        return .command(ParsedCommand(plan: plan, confidence: confidence, imperative: imperative,
                                      explicitRoom: explicitRoom != nil, source: .rules))
    }

    // MARK: Pieces

    static func squash(_ s: String) -> String {
        " " + s.split(separator: " ").joined(separator: " ") + " "
    }

    static func containsAny(_ t: String, _ phrases: [String]) -> Bool {
        phrases.contains { t.contains(" \($0) ") }
    }

    static func isNegated(_ t: String, tokens: [String]) -> Bool {
        if containsAny(t, ["don t", "do not", "dont", "never", "no need", "not"]) { return true }
        // FR: "n'allume pas", "ne ferme pas", "n'éteins jamais".
        let hasNe = tokens.contains("ne") || tokens.contains("n")
        let hasPas = tokens.contains("pas") || tokens.contains("jamais") || tokens.contains("plus")
        return hasNe && hasPas
    }

    static func findVerb(_ t: String, tokens: [String]) -> (DeviceAction, Int, String)? {
        var best: (DeviceAction, Int, String)?
        for (phrase, action) in phraseVerbs {
            guard let range = t.range(of: " \(phrase) ") else { continue }
            let index = t[..<range.lowerBound].split(separator: " ").count
            if best == nil || index < best!.1 { best = (action, index, phrase) }
        }
        for (index, token) in tokens.enumerated() {
            guard let action = verbs[token] else { continue }
            if best == nil || index < best!.1 { best = (action, index, token) }
            break
        }
        // Verbless "lights off", "télé on".
        if best == nil, let last = tokens.last, tokens.count <= 5 {
            if last == "off" { return (.turnOff, 0, "off") }
            if last == "on" { return (.turnOn, 0, "on") }
        }
        return best
    }

    static func findRoom(_ t: String, registry: DeviceRegistry) -> Room? {
        var best: (Room, Int)?
        for room in registry.rooms {
            for name in [room.name] + room.aliases {
                let key = KeywordMatcher.normalize(name)
                guard !key.isEmpty, t.contains(" \(key) ") else { continue }
                if best == nil || key.count > best!.1 { best = (room, key.count) }
            }
        }
        return best?.0
    }

    /// A device named in full ("lampe de chevet", "Sonos cuisine"); longest name wins.
    static let stopWords: Set<String> = ["du", "de", "des", "la", "le", "les", "l", "d", "the", "of", "in", "a", "au", "aux", "my", "mon", "ma", "mes"]

    /// Content words only, so "le plafonnier du salon" matches the name "Plafonnier salon".
    static func content(_ s: String) -> String {
        " " + s.split(separator: " ").map(String.init).filter { !stopWords.contains($0) }.joined(separator: " ") + " "
    }

    /// "du X", "de la X", "de l X", "in the X", "dans le X" where X is neither a room nor a device word.
    static func mentionsUnknownPlace(_ t: String, registry: DeviceRegistry) -> Bool {
        let tokens = t.split(separator: " ").map(String.init)
        let kindKeys = Set(kindWords.map(\.0).flatMap { $0.split(separator: " ").map(String.init) })
        let roomKeys = Set(registry.rooms.flatMap { [$0.name] + $0.aliases }
            .flatMap { KeywordMatcher.normalize($0).split(separator: " ").map(String.init) })
        let ignore: Set<String> = ["son", "volume", "plus", "moins", "suite", "nouveau", "maison", "house", "home", "room", "piece"]
        let modifierOK: Set<String> = ["all", "every", "big", "small", "main", "little", "other", "both"]
        for (k, token) in tokens.enumerated() where k >= 2 && kindKeys.contains(token) && tokens[k - 2] == "the" {
            let word = tokens[k - 1]
            if !stopWords.contains(word), !roomKeys.contains(word), !kindKeys.contains(word), !modifierOK.contains(word),
               !ignore.contains(word) { return true }
        }
        for (i, token) in tokens.enumerated() {
            var next: String?
            if token == "du" || token == "dans" { next = i + 1 < tokens.count ? tokens[i + 1] : nil }
            if (token == "de" || token == "in" || token == "dans"), i + 2 < tokens.count,
               ["la", "l", "the", "le"].contains(tokens[i + 1]) { next = tokens[i + 2] }
            guard let word = next, !["la", "l", "le", "the"].contains(word) else { continue }
            if Double(word) != nil || kindKeys.contains(word) || roomKeys.contains(word) || ignore.contains(word) { continue }
            return true
        }
        return false
    }

    static func findNamedDevice(_ t: String, registry: DeviceRegistry, spokenKind: DeviceKind? = nil) -> Device? {
        let text = content(t)
        let roomKeys = Set(registry.rooms.flatMap { [$0.name] + $0.aliases }.map(KeywordMatcher.normalize))
        var best: (Device, Int)?
        for device in registry.exposedDevices {
            // "ferme les volets du salon" must never pick a TV called "Salon".
            if let spokenKind, !Self.sameFamily(spokenKind, device.kind) { continue }
            for name in [device.name] + device.aliases {
                let key = KeywordMatcher.normalize(name)
                // A bare kind word ("Lumière") is not a name; the room logic handles it.
                guard key.split(separator: " ").count >= 2 || !kindWords.contains(where: { $0.0 == key }),
                      !roomKeys.contains(key), !key.isEmpty, text.contains(content(key)) else { continue }
                if best == nil || key.count > best!.1 { best = (device, key.count) }
            }
        }
        return best?.0
    }

    /// The single kind word that was spoken ("plafonnier", "lampe"), if any.
    static func kindWordSpoken(_ t: String) -> String? {
        kindWords.map(\.0).filter { !$0.contains(" ") }.first { t.contains(" \($0) ") }
    }

    static func sameFamily(_ a: DeviceKind, _ b: DeviceKind) -> Bool {
        a == b || (Set([a, b]) == Set([DeviceKind.tv, .media]))
    }

    static func findKind(_ t: String) -> DeviceKind? {
        // "monte le son de la télé": the TV, not a speaker.
        let tvWords = ["tele", "tv", "television", "televiseur", "telly"]
        if containsAny(t, ["son", "volume"]), containsAny(t, tvWords) { return .tv }
        // Earliest mention wins; longer phrases first at the same spot.
        var best: (DeviceKind, String.Index, Int)?
        for (word, kind) in kindWords {
            guard let range = t.range(of: " \(word) ") else { continue }
            if best == nil || range.lowerBound < best!.1 || (range.lowerBound == best!.1 && word.count > best!.2) {
                best = (kind, range.lowerBound, word.count)
            }
        }
        return best?.0
    }

    static func devices(of kind: DeviceKind, room: Room?, registry: DeviceRegistry) -> [Device] {
        registry.exposedDevices.filter { device in
            device.kind == kind && (room == nil || KeywordMatcher.normalize(device.room ?? "") == room!.id)
        }
    }

    /// Verb × kind. Returns nil when it makes no sense ("open the TV").
    static func map(_ action: DeviceAction, kind: DeviceKind, text t: String) -> DeviceAction? {
        switch kind {
        case .light, .outlet, .fan, .tv, .media:
            switch action {
            case .turnOn, .open: return .turnOn          // "ouvre la lumière" (Québec)
            case .turnOff, .close, .stop: return .turnOff
            case .raise: return kind == .outlet ? nil : .raise
            case .lower: return kind == .outlet ? nil : .lower
            case .setTemperature:
                // "mets la télé" = turn it on; "set the lamp to 21" makes no sense.
                return Self.number(in: t.split(separator: " ").map(String.init)) == nil ? .turnOn : nil
            default: return nil
            }
        case .shutter:
            switch action {
            case .open, .raise: return .open
            case .close, .lower: return .close
            case .stop, .turnOff: return .stop
            default: return nil
            }
        case .scene:
            return action == .turnOn || action == .setTemperature ? .turnOn : nil
        case .thermostat:
            switch action {
            case .turnOn: return .turnOn
            case .turnOff, .stop: return .turnOff
            case .raise: return .raise
            case .lower: return .lower
            case .setTemperature: return .setTemperature
            default: return nil
            }
        case .cameraPrivacy:
            switch action {
            case .turnOn: return .turnOn
            case .turnOff, .stop: return .turnOff
            default: return nil
            }
        case .garageDoor:
            switch action {
            case .open, .raise, .turnOn: return .open
            case .close, .lower, .turnOff: return .close
            case .stop: return .stop
            default: return nil
            }
        case .lock:
            switch action {
            case .lock, .close: return .lock
            case .unlock, .open: return .unlock
            default: return nil
            }
        case .alarm:
            switch action {
            case .arm, .turnOn: return .arm
            case .disarm, .turnOff, .stop: return .disarm
            default: return nil
            }
        case .sensor:
            return nil
        }
    }

    static let numberWords: [String: Double] = [
        "quinze": 15, "seize": 16, "dix sept": 17, "dix huit": 18, "dix neuf": 19, "vingt": 20, "vingt et un": 21,
        "vingt deux": 22, "vingt trois": 23, "vingt quatre": 24, "vingt cinq": 25,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
        "twenty one": 21, "twenty two": 22, "twenty three": 23, "twenty four": 24, "twenty five": 25,
    ]

    static func number(in tokens: [String]) -> Double? {
        for (i, token) in tokens.enumerated() {
            if let value = Double(token) {
                // "21 5" = 21.5 (the normaliser splits "21,5").
                if i + 1 < tokens.count, tokens[i + 1].count == 1, let decimal = Double(tokens[i + 1]) { return value + decimal / 10 }
                return value
            }
        }
        let text = " " + tokens.joined(separator: " ") + " "
        return numberWords.sorted { $0.key.count > $1.key.count }.first { text.contains(" \($0.key) ") }?.value
    }

    // MARK: Status questions

    func queryCommand(_ t: String, tokens: [String], registry: DeviceRegistry, camera: String?) -> ParseResult? {
        let markers = ["est ce que", "is the", "are the", "is my", "are my", "is it", "est elle", "est il", "sont elles", "sont ils"]
        let temperature = ["il fait combien", "quelle temperature", "what s the temperature", "what is the temperature",
                           "how warm", "how cold", "combien il fait"]
        let isTemperature = Self.containsAny(t, temperature)
        let marked = Self.containsAny(t, markers) || isTemperature
        let frState = tokens.contains { Self.stateWordsFR[$0] != nil } && (tokens.contains("est") || tokens.contains("sont"))
        guard marked || (frState && Self.verbs[tokens.first ?? ""] == nil) else { return nil }
        let explicitRoom = Self.findRoom(t, registry: registry)
        let room = explicitRoom ?? camera.flatMap(registry.room(forCamera:))
        var targets: [Device] = []
        if isTemperature {
            targets = Self.devices(of: .thermostat, room: room, registry: registry)
        } else if let named = Self.findNamedDevice(t, registry: registry) {
            targets = [named]
        } else if let kind = Self.findKind(t) {
            targets = Self.devices(of: kind, room: room, registry: registry)
            if targets.isEmpty, explicitRoom == nil {
                let all = Self.devices(of: kind, room: nil, registry: registry)
                if all.count == 1 { targets = all }
            }
        }
        guard !targets.isEmpty else { return .unsure(t.trimmingCharacters(in: .whitespaces)) }
        let plan = ActionPlan(action: .query, targets: targets, room: room?.name)
        return .command(ParsedCommand(plan: plan, confidence: 0.9, imperative: false, explicitRoom: explicitRoom != nil,
                                      source: .rules))
    }
}
