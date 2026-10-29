import Foundation
import Testing
@testable import LumenAssistant

/// FR + EN matrix: what the rule parser must do with each sentence (command
/// part only, i.e. after "Lumen,"). `camera` gives the default room.
struct ParserCase: Sendable, CustomTestStringConvertible {
    enum Expect: Sendable {
        case command(DeviceAction, Set<String>, Double? = nil)
        case not(NotCommandReason)
        case unsure
    }
    var text: String
    var camera: String = "salon"
    var expect: Expect
    var testDescription: String { text }

    init(_ text: String, camera: String = "salon", _ expect: Expect) {
        self.text = text
        self.camera = camera
        self.expect = expect
    }
}

let salonLights: Set<String> = ["light.salon_plafond", "light.salon_lampe"]
let allLights: Set<String> = ["light.salon_plafond", "light.salon_lampe", "light.cuisine", "light.chambre"]

let parserMatrix: [ParserCase] = [
    // French commands
    .init("allume la lumière du salon", .command(.turnOn, salonLights)),
    .init("éteins la lumière de la cuisine", .command(.turnOff, ["light.cuisine"])),
    .init("allume la lumière", .command(.turnOn, salonLights)),
    .init("allume le plafonnier du salon", .command(.turnOn, ["light.salon_plafond"])),
    .init("ferme les volets du salon", .command(.close, ["cover.volets_salon"])),
    .init("ouvre les volets", .command(.open, ["cover.volets_salon"])),
    .init("monte le volet de la chambre", .command(.open, ["cover.volet_chambre"])),
    .init("baisse les volets du séjour", .command(.close, ["cover.volets_salon"])),
    .init("arrête les volets", .command(.stop, ["cover.volets_salon"])),
    .init("allume la télé", .command(.turnOn, ["media_player.tv_salon"])),
    .init("éteins la télé", camera: "cuisine", .command(.turnOff, ["media_player.tv_salon"])),
    .init("monte le son de la télé", .command(.raise, ["media_player.tv_salon"])),
    .init("baisse le son", camera: "cuisine", .command(.lower, ["media_player.sonos_cuisine"])),
    .init("mets le chauffage à 21", .command(.setTemperature, ["climate.salon"], 21)),
    .init("règle le thermostat sur 19 degrés", .command(.setTemperature, ["climate.salon"], 19)),
    .init("monte le chauffage", .command(.raise, ["climate.salon"])),
    .init("tu peux allumer la lampe de la chambre", .command(.turnOn, ["light.chambre"])),
    .init("peux-tu éteindre la lumière de la cuisine s'il te plaît", .command(.turnOff, ["light.cuisine"])),
    .init("allume le sapin", .command(.turnOn, ["switch.sapin"])),
    .init("allume le ventilateur de la chambre", .command(.turnOn, ["fan.chambre"])),
    .init("éteins toutes les lumières", .command(.turnOff, allLights)),
    .init("déverrouille la porte d'entrée", .command(.unlock, ["lock.porte_entree"])),
    .init("ouvre le garage", .command(.open, ["cover.garage"])),
    .init("active l'alarme", .command(.arm, ["alarm_control_panel.maison"])),
    .init("désactive l'alarme", .command(.disarm, ["alarm_control_panel.maison"])),
    .init("coupe la caméra du salon", .command(.turnOff, ["camera.salon"])),
    .init("ferme la porte d'entrée", .command(.lock, ["lock.porte_entree"])),
    .init("est-ce que la lumière de la cuisine est allumée", .command(.query, ["light.cuisine"])),
    .init("la télé est allumée", .command(.query, ["media_player.tv_salon"])),
    .init("mets la télé", .command(.turnOn, ["media_player.tv_salon"])),
    .init("ouvre la lumière de la chambre", .command(.turnOn, ["light.chambre"])),
    .init("lance la musique", camera: "cuisine", .command(.turnOn, ["media_player.sonos_cuisine"])),
    .init("allume la lumière de l'entrée", .unsure),
    .init("allume la lampe du bureau", .unsure),
    .init("allume le truc", .unsure),
    // English commands
    .init("turn on the living room light", .command(.turnOn, salonLights)),
    .init("turn off the kitchen light", .command(.turnOff, ["light.cuisine"])),
    .init("turn the bedroom lamp off", .command(.turnOff, ["light.chambre"])),
    .init("switch on the TV", .command(.turnOn, ["media_player.tv_salon"])),
    .init("open the living room shutters", .command(.open, ["cover.volets_salon"])),
    .init("close the bedroom blinds", .command(.close, ["cover.volet_chambre"])),
    .init("lower the shutters", .command(.close, ["cover.volets_salon"])),
    .init("dim the lights", .command(.lower, salonLights)),
    .init("set the thermostat to 20", .command(.setTemperature, ["climate.salon"], 20)),
    .init("turn up the heating", .command(.raise, ["climate.salon"])),
    .init("can you turn off the lights in the kitchen please", .command(.turnOff, ["light.cuisine"])),
    .init("unlock the front door", .command(.unlock, ["lock.porte_entree"])),
    .init("open the garage door", .command(.open, ["cover.garage"])),
    .init("disarm the alarm", .command(.disarm, ["alarm_control_panel.maison"])),
    .init("is the kitchen light on", .command(.query, ["light.cuisine"])),
    .init("stop the shutters", .command(.stop, ["cover.volets_salon"])),
    .init("turn off all the lights", .command(.turnOff, allLights)),
    .init("lights off", .command(.turnOff, salonLights)),
    .init("turn on the fan in the bedroom", .command(.turnOn, ["fan.chambre"])),
    // French: not requests
    .init("il faudrait allumer la lumière un jour", .not(.hedge)),
    .init("n'allume pas la lumière", .not(.negation)),
    .init("j'ai allumé la lumière du salon", .not(.pastOrReport)),
    .init("si tu allumes la télé je pars", .not(.conditional)),
    .init("pourquoi la lumière est allumée", .not(.openQuestion)),
    .init("on éteint la télé", .not(.firstPerson)),
    .init("tu devrais fermer les volets", .not(.hedge)),
    .init("je vais éteindre la lumière", .not(.firstPerson)),
    .init("demain il faut ouvrir les volets", .not(.hedge)),
    .init("le film commence à huit heures", .not(.noVerb)),
    .init("allume la lumière ce soir", .not(.hedge)),
    .init("chéri tu as fermé la porte", .not(.pastOrReport)),
    .init("peut-être qu'on pourrait baisser le chauffage", .not(.hedge)),
    .init("quand j'ouvre les volets il fait froid", .not(.conditional)),
    // English: not requests
    .init("we should turn off the lights", .not(.hedge)),
    .init("don't turn on the TV", .not(.negation)),
    .init("I turned off the kitchen light", .not(.pastOrReport)),
    .init("if you open the shutters it gets cold", .not(.conditional)),
    .init("why is the light on", .not(.openQuestion)),
    .init("maybe later we can close the blinds", .not(.hedge)),
    .init("did you lock the front door", .not(.pastOrReport)),
    .init("let's turn on the TV", .not(.firstPerson)),
    .init("I'll close the blinds", .not(.hedge)),
    .init("who left the lights on", .not(.openQuestion)),
]

@Suite struct ParserMatrixTests {
    let parser = RuleParser()

    @Test(arguments: parserMatrix)
    func matrix(_ c: ParserCase) {
        let result = parser.parse(c.text, registry: Fixture.registry, camera: c.camera)
        switch c.expect {
        case .command(let action, let ids, let value):
            guard case .command(let cmd) = result else {
                Issue.record("expected \(action) \(ids), got \(result)")
                return
            }
            #expect(cmd.plan.action == action)
            #expect(Set(cmd.plan.targets.map(\.entityID)) == ids)
            if let value { #expect(cmd.plan.value == value) }
        case .not(let reason):
            #expect(result == .notACommand(reason), "got \(result)")
        case .unsure:
            guard case .unsure = result else {
                Issue.record("expected unsure, got \(result)")
                return
            }
        }
    }

    @Test func matrixSizeAndAccuracy() {
        #expect(parserMatrix.count >= 60)
        var correct = 0
        for c in parserMatrix {
            let r = parser.parse(c.text, registry: Fixture.registry, camera: c.camera)
            switch (c.expect, r) {
            case (.command(let a, let ids, _), .command(let cmd)):
                if cmd.plan.action == a, Set(cmd.plan.targets.map(\.entityID)) == ids { correct += 1 }
            case (.not(let reason), .notACommand(let got)): if reason == got { correct += 1 }
            case (.unsure, .unsure): correct += 1
            default: break
            }
        }
        print("PARSER-ACCURACY \(correct)/\(parserMatrix.count)")
        #expect(correct == parserMatrix.count)
    }

    @Test func neverResolvesUnexposedDevices() {
        for text in ["allume la lampe bureau", "turn on lampe bureau", "allume la lumière du bureau"] {
            let r = parser.parse(text, registry: Fixture.registry, camera: "salon")
            #expect(r.command?.plan.targets.contains { $0.entityID == "light.bureau" } != true)
        }
    }

    @Test func nameNeverBeatsSpokenKind() {
        // A TV called "Salon" must not answer "ferme les volets du salon".
        var reg = Fixture.registry
        reg.devices.append(Device(entityID: "media_player.salon", name: "Salon", kind: .tv, room: "Salon"))
        let r = parser.parse("ferme les volets du salon", registry: reg, camera: "cuisine")
        #expect(r.command?.plan.targets.map(\.entityID) == ["cover.volets_salon"])
    }

    @Test func parserIsFast() {
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<20 { for c in parserMatrix { _ = parser.parse(c.text, registry: Fixture.registry, camera: c.camera) } }
        let perCall = start.duration(to: clock.now) / (20 * parserMatrix.count)
        print("PARSER-LATENCY per utterance: \(perCall)")
        #expect(perCall < .milliseconds(5))
    }
}
