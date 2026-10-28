import CryptoKit
import Foundation

@main
enum AutomationAuthorityFixtureHarness {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw HarnessError("usage: automation-authority-fixture-harness <fixture.json>")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let fixture = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let policyJSON = fixture["policyJSON"] as? String,
              let revision = fixture["revision"] as? Int,
              let timeZone = fixture["timeZone"] as? String,
              let keyText = fixture["decisionKeyBase64"] as? String,
              let key = Data(base64Encoded: keyText),
              let policyHash = fixture["policyHash"] as? String,
              let nowText = fixture["now"] as? String,
              let now = ISO8601DateFormatter.fixture.date(from: nowText),
              let eventJSON = fixture["event"] as? [String: Any],
              let expected = fixture["expected"] as? [String: Any] else {
            throw HarnessError("fixture structure is invalid")
        }
        let policyData = Data(policyJSON.utf8)
        let actualHash = "sha256:" + SHA256.hash(data: policyData)
            .map { String(format: "%02x", $0) }.joined()
        try require(actualHash == policyHash, "policy hash drift")

        let event = FrigateMQTTClient.Event(
            id: try string(eventJSON, "eventId"),
            camera: try string(eventJSON, "camera"),
            label: try string(eventJSON, "label"),
            zones: [],
            topScore: try number(eventJSON, "score"),
            startTime: now,
            kind: .new,
            subLabel: nil,
            stationary: false,
            hasClip: true,
            recognizedPlate: nil,
            reviewID: try string(eventJSON, "reviewId"),
            reviewSeverity: try string(eventJSON, "reviewSeverity")
        )
        let store = MemoryKVS()
        store.set(policyData, forKey: "automation_rules_v4")
        store.set(Int64(revision), forKey: "automation_rules_v4_revision")
        store.set(policyHash, forKey: "automation_rules_v4_hash")
        store.set(timeZone, forKey: "automation_rules_v4_timezone")
        let suite = "lumen-automation-fixture-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw HarnessError("defaults unavailable") }
        defer { defaults.removePersistentDomain(forName: suite) }

        let authority = AutomationPolicyAuthority(store: store, defaults: defaults, keyProvider: { key })
        try require(authority.refreshAndAcknowledge(now: now), "policy acknowledgement failed")
        let first = try delivery(authority.evaluate(event: event, now: now))
        try require(first.ruleID == string(expected, "ruleId"), "rule mismatch")
        try require(first.branchID == string(expected, "branchId"), "branch mismatch")
        try require(first.decisionID == string(expected, "decisionId"), "decision id mismatch")
        try require(first.disposition.rawValue == string(expected, "disposition"), "disposition mismatch")
        try require(first.priority == string(expected, "priority"), "priority mismatch")
        try require(first.category == string(expected, "category"), "category mismatch")
        try require(first.spokenTemplate == string(expected, "spokenTemplate"), "spoken mismatch")
        try require(first.criticalVolume == number(expected, "criticalVolume"), "volume mismatch")
        try require(first.decisionMAC == string(expected, "decisionMAC"), "MAC mismatch")

        // A recreated authority must reload last-fired state and not replay the
        // rule before its 300-second cooldown expires.
        let restarted = AutomationPolicyAuthority(store: store, defaults: defaults, keyProvider: { key })
        let blocked = try delivery(restarted.evaluate(event: event, now: now.addingTimeInterval(100)))
        try require(blocked.ruleID == "00000000-0000-0000-0000-000000000000", "restart replayed cooldown action")
        let afterCooldown = try delivery(restarted.evaluate(event: event, now: now.addingTimeInterval(301)))
        try require(afterCooldown.ruleID == first.ruleID, "rule did not resume after cooldown")

        store.set("sha256:" + String(repeating: "0", count: 64), forKey: "automation_rules_v4_hash")
        guard case .suppress = restarted.evaluate(event: event, now: now.addingTimeInterval(601)) else {
            throw HarnessError("tampered policy did not fail closed")
        }
        try require(!restarted.refreshAndAcknowledge(now: now), "tampered policy was acknowledged")
        print("Automation authority fixture: 14 checks passed")
    }

    private static func delivery(_ result: AutomationPolicyAuthority.Evaluation) throws -> BridgeAutomationDecision {
        guard case .deliver(let decision) = result else { throw HarnessError("expected signed delivery") }
        return decision
    }

    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw HarnessError("missing string \(key)") }
        return value
    }

    private static func number(_ object: [String: Any], _ key: String) throws -> Double {
        guard let value = object[key] as? NSNumber else { throw HarnessError("missing number \(key)") }
        return value.doubleValue
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw HarnessError(message) }
    }
}

private struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private extension ISO8601DateFormatter {
    static let fixture: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
