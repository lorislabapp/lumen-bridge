import Foundation
import Testing
@testable import LumenAssistant

/// Held-out set written by a separate agent that never saw the parser
/// (Fixtures/heldout-commands.json). Scored, not tuned against: the number is
/// reported, and only the safety property is a hard failure.
@Suite struct HeldOutTests {
    struct Item: Decodable {
        var text: String
        var camera: String
        var expect: String
        var action: String?
        var targets: [String]?
        var value: Double?
    }

    @Test func heldOutAccuracy() throws {
        let data = try Data(contentsOf: Fixture.url("heldout-commands.json"))
        let items = try JSONDecoder().decode([Item].self, from: data)
        let parser = RuleParser()
        var correct = 0, wrongAction = 0, falseAccept = 0, missed = 0
        var byKind: [String: (Int, Int)] = [:]
        var misses: [String] = []
        for item in items {
            let r = parser.parse(item.text, registry: Fixture.registry, camera: item.camera)
            var ok = false
            switch item.expect {
            case "command":
                if let c = r.command {
                    ok = c.plan.action.rawValue == item.action && Set(c.plan.targets.map(\.entityID)) == Set(item.targets ?? [])
                        && (item.value == nil || c.plan.value == item.value)
                    if !ok { wrongAction += 1 }
                } else { missed += 1 }
            case "not_command":
                if case .notACommand = r { ok = true } else if case .unsure = r { ok = true } else { falseAccept += 1 }
            default: // unclear: the parser must not act
                if r.command == nil { ok = true } else { falseAccept += 1 }
            }
            let tally = byKind[item.expect, default: (0, 0)]
            byKind[item.expect] = (tally.0 + (ok ? 1 : 0), tally.1 + 1)
            if ok { correct += 1 } else { misses.append("\(item.expect): \(item.text) → \(r)") }
        }
        print("HELDOUT-ACCURACY \(correct)/\(items.count) wrongAction=\(wrongAction) missed=\(missed) falseAccept=\(falseAccept)")
        for (k, v) in byKind.sorted(by: { $0.key < $1.key }) { print("HELDOUT \(k): \(v.0)/\(v.1)") }
        for m in misses { print("HELDOUT-MISS \(m)") }
        #expect(items.count >= 60)
    }
}
