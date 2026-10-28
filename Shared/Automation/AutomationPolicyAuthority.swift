import CryptoKit
import Foundation
import Security
import os

private let automationLogger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "AutomationAuthority")

nonisolated struct BridgeAutomationDecision: Sendable, Equatable {
    enum Disposition: String, Sendable { case normal, critical, suppress }

    let automationSchema: String
    let policyRevision: Int64
    let policyHash: String
    let ruleID: String
    let branchID: String
    let decisionID: String
    let disposition: Disposition
    let priority: String
    let category: String?
    let spokenTemplate: String?
    let criticalVolume: Double?
    let decisionMAC: String
}

@MainActor
final class AutomationPolicyAuthority {
    enum Evaluation {
        case passthrough
        case suppress(String)
        case deliver(BridgeAutomationDecision)
    }

    private enum Truth { case yes, no, unknown }

    private static let policyDataKey = "automation_rules_v4"
    private static let policyRevisionKey = "automation_rules_v4_revision"
    private static let policyHashKey = "automation_rules_v4_hash"
    private static let policyTimeZoneKey = "automation_rules_v4_timezone"
    private static let ackRevisionKey = "automation_rules_v4_ack_revision"
    private static let ackHashKey = "automation_rules_v4_ack_hash"
    private static let ackBridgeKey = "automation_rules_v4_ack_bridge"
    private static let ackTimestampKey = "automation_rules_v4_ack_timestamp"
    private static let ackMACKey = "automation_rules_v4_ack_mac"
    private static let ackTimeZoneKey = "automation_rules_v4_ack_timezone"
    private static let schema = "lumen-automation-decision-v1"
    private static let zeroID = "00000000-0000-0000-0000-000000000000"
    private static let lastFiredKey = "lumenbridge.automation.last-fired.v1"

    private let store: NSUbiquitousKeyValueStore
    private let defaults: UserDefaults
    private let bridgeID: String
    private let keyProvider: () -> Data?
    private var lastFired: [String: TimeInterval]

    init(
        store: NSUbiquitousKeyValueStore = .default,
        defaults: UserDefaults = .standard,
        keyProvider: @escaping () -> Data? = { SharedAutomationKey.read() }
    ) {
        self.store = store
        self.defaults = defaults
        self.keyProvider = keyProvider
        if let existing = defaults.string(forKey: "lumenbridge.automation.bridge-id"), !existing.isEmpty {
            bridgeID = existing
        } else {
            let generated = UUID().uuidString.lowercased()
            defaults.set(generated, forKey: "lumenbridge.automation.bridge-id")
            bridgeID = generated
        }
        lastFired = defaults.dictionary(forKey: Self.lastFiredKey) as? [String: TimeInterval] ?? [:]
    }

    @discardableResult
    func refreshAndAcknowledge(now: Date = Date()) -> Bool {
        store.synchronize()
        guard let policy = loadPolicy(), policy.isSupported, !policy.bridgeRules.isEmpty,
              let key = keyProvider() else {
            clearAcknowledgement()
            return false
        }
        let timestamp = Int64(now.timeIntervalSince1970)
        let input = [String(policy.revision), policy.hash, policy.timeZone.identifier, bridgeID, String(timestamp)]
            .joined(separator: "\n")
        store.set(policy.revision, forKey: Self.ackRevisionKey)
        store.set(policy.hash, forKey: Self.ackHashKey)
        store.set(bridgeID, forKey: Self.ackBridgeKey)
        store.set(timestamp, forKey: Self.ackTimestampKey)
        store.set(Self.sign(input, key: key), forKey: Self.ackMACKey)
        store.set(policy.timeZone.identifier, forKey: Self.ackTimeZoneKey)
        store.synchronize()
        return true
    }

    func evaluate(event: FrigateMQTTClient.Event, now: Date = Date()) -> Evaluation {
        guard let data = store.data(forKey: Self.policyDataKey) else { return .passthrough }
        guard let policy = loadPolicy(data: data), policy.isSupported else {
            return .suppress("Automation policy is invalid or uses unsupported always-on primitives")
        }
        guard !policy.bridgeRules.isEmpty else { return .passthrough }
        guard let key = keyProvider() else {
            return .suppress("Automation signing key unavailable")
        }

        var selectedRule = Self.zeroID
        var selectedBranch = Self.zeroID
        var disposition: BridgeAutomationDecision.Disposition = .normal
        var priority = "normal"
        var category: String?
        var spokenTemplate: String?
        var criticalVolume: Double?

        for rule in policy.bridgeRules {
            guard let ruleID = rule["id"] as? String,
                  let branches = rule["branches"] as? [[String: Any]] else { continue }
            if let cooldown = rule["cooldownSeconds"] as? Int,
               let fired = lastFired[ruleID], now.timeIntervalSince1970 - fired < Double(cooldown) {
                continue
            }

            var match: [String: Any]?
            var sawUnknown = false
            for branch in branches {
                let kind = branch["kind"] as? String
                if kind == "else" {
                    if !sawUnknown { match = branch }
                    break
                }
                guard let expression = branch["expression"] as? [String: Any] else { continue }
                switch evaluateExpression(
                    expression, event: event, now: now, timeZone: policy.timeZone, ruleID: ruleID
                ) {
                case .yes: match = branch
                case .no: break
                case .unknown: sawUnknown = true
                }
                if match != nil { break }
                if sawUnknown { break }
            }
            if sawUnknown && match == nil {
                return .suppress("Automation predicate input unavailable")
            }
            guard let match, let branchID = match["id"] as? String,
                  let actions = match["actions"] as? [[String: Any]] else { continue }
            lastFired[ruleID] = now.timeIntervalSince1970
            defaults.set(lastFired, forKey: Self.lastFiredKey)
            if selectedRule == Self.zeroID { selectedRule = ruleID; selectedBranch = branchID }

            for action in actions {
                if action["suppressNotification"] != nil {
                    return .suppress("Suppressed by Automation V4 policy")
                }
                if let value = action["notification"] as? [String: Any] {
                    if value["priority"] as? String == "timeSensitive" { priority = "timeSensitive" }
                    if let candidate = value["category"] as? String, !candidate.isEmpty { category = candidate }
                }
                if let value = action["criticalAlert"] as? [String: Any] {
                    disposition = .critical
                    priority = "timeSensitive"
                    criticalVolume = min(max((value["volume"] as? Double) ?? 1, 0), 1)
                    if let candidate = value["category"] as? String, !candidate.isEmpty { category = candidate }
                }
                if let value = action["spokenAnnouncement"] as? [String: Any] {
                    spokenTemplate = value["template"] as? String
                    if value["critical"] as? Bool == true {
                        disposition = .critical
                        priority = "timeSensitive"
                        criticalVolume = criticalVolume ?? 1
                    }
                }
            }
        }

        let decisionID = "\(event.reviewID ?? event.id)/\(event.reviewSeverity ?? "detection")/\(policy.revision)"
        let unsigned = BridgeAutomationDecision(
            automationSchema: Self.schema,
            policyRevision: policy.revision,
            policyHash: policy.hash,
            ruleID: selectedRule,
            branchID: selectedBranch,
            decisionID: decisionID,
            disposition: disposition,
            priority: priority,
            category: category,
            spokenTemplate: spokenTemplate,
            criticalVolume: criticalVolume,
            decisionMAC: ""
        )
        let mac = Self.sign(Self.signingInput(event: event, decision: unsigned), key: key)
        return .deliver(.init(
            automationSchema: unsigned.automationSchema,
            policyRevision: unsigned.policyRevision,
            policyHash: unsigned.policyHash,
            ruleID: unsigned.ruleID,
            branchID: unsigned.branchID,
            decisionID: unsigned.decisionID,
            disposition: unsigned.disposition,
            priority: unsigned.priority,
            category: unsigned.category,
            spokenTemplate: unsigned.spokenTemplate,
            criticalVolume: unsigned.criticalVolume,
            decisionMAC: mac
        ))
    }

    private struct LoadedPolicy {
        let revision: Int64
        let hash: String
        let rules: [[String: Any]]
        let timeZone: TimeZone
        let isSupported: Bool

        var bridgeRules: [[String: Any]] {
            rules.filter {
                ($0["enabled"] as? Bool) == true
                    && ($0["sideEffectAuthority"] as? String) == "bridgeRequired"
            }
        }
    }

    private func loadPolicy() -> LoadedPolicy? {
        guard let data = store.data(forKey: Self.policyDataKey) else { return nil }
        return loadPolicy(data: data)
    }

    private func loadPolicy(data: Data) -> LoadedPolicy? {
        let revision = store.longLong(forKey: Self.policyRevisionKey)
        let advertisedHash = store.string(forKey: Self.policyHashKey) ?? ""
        let timeZoneIdentifier = store.string(forKey: Self.policyTimeZoneKey) ?? ""
        let actualHash = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard revision > 0, advertisedHash == actualHash,
              let timeZone = TimeZone(identifier: timeZoneIdentifier),
              let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return LoadedPolicy(
            revision: revision,
            hash: actualHash,
            rules: rules,
            timeZone: timeZone,
            isSupported: rules.allSatisfy(policyRuleIsSupported)
        )
    }

    private func policyRuleIsSupported(_ rule: [String: Any]) -> Bool {
        guard (rule["schemaVersion"] as? Int) == 4,
              let id = rule["id"] as? String, !id.isEmpty, id.count <= 64,
              let name = rule["name"] as? String, !name.isEmpty, name.count <= 256,
              let branches = rule["branches"] as? [[String: Any]], !branches.isEmpty else { return false }
        if let cooldown = rule["cooldownSeconds"] as? Int, !(0...604_800).contains(cooldown) { return false }
        if (rule["enabled"] as? Bool) != true || (rule["sideEffectAuthority"] as? String) != "bridgeRequired" { return true }
        var sawElse = false
        for (index, branch) in branches.enumerated() {
            guard let branchID = branch["id"] as? String, !branchID.isEmpty, branchID.count <= 64,
                  let kind = branch["kind"] as? String else { return false }
            if kind == "if" {
                if index != 0 { return false }
            } else if kind == "elseIf" {
                if index == 0 || sawElse { return false }
            } else if kind == "else" {
                if index == 0 || sawElse || index != branches.count - 1 || branch["expression"] != nil { return false }
                sawElse = true
            } else { return false }
            if kind != "else" {
                guard let expression = branch["expression"] as? [String: Any],
                      expressionIsSupported(expression) else { return false }
            }
            guard let actions = branch["actions"] as? [[String: Any]], !actions.isEmpty else { return false }
            guard actions.allSatisfy(actionIsSupported) else { return false }
            let actionNames = actions.compactMap { $0.keys.first }
            if actionNames.contains("suppressNotification") && actionNames.count != 1 { return false }
            if actionNames.filter({ $0 == "notification" || $0 == "criticalAlert" }).count > 1 { return false }
        }
        return true
    }

    private func actionIsSupported(_ action: [String: Any]) -> Bool {
        guard action.count == 1, let name = action.keys.first,
              let value = action[name] as? [String: Any] else { return false }
        let categoryIsValid: Bool
        if let category = value["category"] as? String {
            categoryIsValid = !category.isEmpty && category.count <= 64
        } else {
            categoryIsValid = value["category"] == nil || value["category"] is NSNull
        }
        switch name {
        case "notification":
            return ["normal", "timeSensitive"].contains(value["priority"] as? String ?? "")
                && categoryIsValid
        case "criticalAlert":
            guard let volume = value["volume"] as? Double else { return false }
            return (0...1).contains(volume) && categoryIsValid
        case "spokenAnnouncement":
            return ["personAtDoor", "detectionAtCamera", "criticalDetection"]
                .contains(value["template"] as? String ?? "") && value["critical"] is Bool
        case "suppressNotification": return value.isEmpty
        default: return false
        }
    }

    private func expressionIsSupported(_ expression: [String: Any]) -> Bool {
        guard let kind = expression["kind"] as? String else { return false }
        switch kind {
        case "all", "any":
            guard let parts = expression["parts"] as? [[String: Any]], !parts.isEmpty else { return false }
            return parts.allSatisfy(expressionIsSupported)
        case "not":
            guard let nested = expression["expression"] as? [String: Any] else { return false }
            return expressionIsSupported(nested)
        case "condition":
            guard let condition = expression["condition"] as? [String: Any], condition.count == 1,
                  let name = condition.keys.first else { return false }
            let supported: Set<String> = [
                "camera", "label", "zone", "subLabel", "confidence", "timeOfDay", "dayOfWeek",
                "recognizedFace", "unknownFace", "recognizedPlate", "unknownPlate", "stationary",
                "hasClip", "perRuleCooldown"
            ]
            return supported.contains(name) && conditionPayloadIsSupported(name, condition[name])
        default: return false
        }
    }

    private func conditionPayloadIsSupported(_ name: String, _ raw: Any?) -> Bool {
        guard let value = raw as? [String: Any] else { return false }
        func validString(_ candidate: Any?, max: Int = 256) -> Bool {
            guard let text = candidate as? String else { return false }
            return !text.isEmpty && text.count <= max
        }
        switch name {
        case "camera", "label": return validString(value["name"])
        case "zone": return validString(value["camera"]) && validString(value["zone"])
        case "subLabel": return validString(value["value"])
        case "confidence":
            guard ["gt", "gte", "lt", "lte", "eq"].contains(value["comparison"] as? String ?? ""),
                  let number = value["value"] as? Double else { return false }
            return (0...1).contains(number)
        case "timeOfDay":
            guard let start = value["startMinutes"] as? Int, let end = value["endMinutes"] as? Int else { return false }
            return (0..<1_440).contains(start) && (0..<1_440).contains(end)
        case "dayOfWeek":
            guard let mask = value["daysMask"] as? Int else { return false }
            return (1...127).contains(mask)
        case "recognizedFace":
            guard let names = value["names"] as? [String], (1...64).contains(names.count) else { return false }
            return names.allSatisfy { !$0.isEmpty && $0.count <= 128 }
        case "recognizedPlate":
            guard let plates = value["plates"] as? [String], (1...64).contains(plates.count) else { return false }
            return plates.allSatisfy { !$0.isEmpty && $0.count <= 64 }
        case "stationary": return value["stationary"] is Bool
        case "perRuleCooldown":
            guard let seconds = value["seconds"] as? Int else { return false }
            return (0...604_800).contains(seconds)
        case "unknownFace", "unknownPlate", "hasClip": return value.isEmpty
        default: return false
        }
    }

    private func evaluateExpression(
        _ expression: [String: Any], event: FrigateMQTTClient.Event, now: Date,
        timeZone: TimeZone, ruleID: String
    ) -> Truth {
        guard let kind = expression["kind"] as? String else { return .unknown }
        switch kind {
        case "all":
            guard let parts = expression["parts"] as? [[String: Any]], !parts.isEmpty else { return .unknown }
            var unknown = false
            for part in parts {
                switch evaluateExpression(
                    part, event: event, now: now, timeZone: timeZone, ruleID: ruleID
                ) {
                case .no: return .no
                case .unknown: unknown = true
                case .yes: break
                }
            }
            return unknown ? .unknown : .yes
        case "any":
            guard let parts = expression["parts"] as? [[String: Any]], !parts.isEmpty else { return .unknown }
            var unknown = false
            for part in parts {
                switch evaluateExpression(
                    part, event: event, now: now, timeZone: timeZone, ruleID: ruleID
                ) {
                case .yes: return .yes
                case .unknown: unknown = true
                case .no: break
                }
            }
            return unknown ? .unknown : .no
        case "not":
            guard let nested = expression["expression"] as? [String: Any] else { return .unknown }
            switch evaluateExpression(
                nested, event: event, now: now, timeZone: timeZone, ruleID: ruleID
            ) {
            case .yes: return .no
            case .no: return .yes
            case .unknown: return .unknown
            }
        case "condition":
            guard let condition = expression["condition"] as? [String: Any] else { return .unknown }
            return evaluateCondition(
                condition, event: event, now: now, timeZone: timeZone, ruleID: ruleID
            )
        default: return .unknown
        }
    }

    private func evaluateCondition(
        _ condition: [String: Any], event: FrigateMQTTClient.Event, now: Date,
        timeZone: TimeZone, ruleID: String
    ) -> Truth {
        guard condition.count == 1, let name = condition.keys.first else { return .unknown }
        let value = condition[name] as? [String: Any] ?? [:]
        switch name {
        case "camera": return truth(event.camera == value["name"] as? String)
        case "label": return truth(event.label == value["name"] as? String)
        case "zone":
            guard let camera = value["camera"] as? String, let zone = value["zone"] as? String else { return .unknown }
            return truth(event.camera == camera && event.zones.contains(zone))
        case "subLabel":
            guard let expected = value["value"] as? String, let actual = event.subLabel else { return event.subLabel == nil ? .no : .unknown }
            return truth(actual == expected)
        case "confidence":
            guard let comparison = value["comparison"] as? String, let target = value["value"] as? Double else { return .unknown }
            return truth(compare(event.topScore, target, comparison))
        case "timeOfDay":
            guard let start = value["startMinutes"] as? Int, let end = value["endMinutes"] as? Int else { return .unknown }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let components = calendar.dateComponents([.hour, .minute], from: now)
            let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            return truth(start <= end ? (minute >= start && minute <= end) : (minute >= start || minute <= end))
        case "dayOfWeek":
            guard let mask = value["daysMask"] as? Int else { return .unknown }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let weekday = calendar.component(.weekday, from: now)
            let bit = weekday == 1 ? 6 : weekday - 2
            return truth((mask & (1 << bit)) != 0)
        case "recognizedFace":
            guard let names = value["names"] as? [String], let face = event.subLabel else { return .no }
            return truth(names.contains(face))
        case "unknownFace": return truth(event.label == "person" && event.subLabel == nil)
        case "recognizedPlate":
            guard let plates = value["plates"] as? [String], let plate = event.recognizedPlate else { return .no }
            return truth(plates.map(normalizePlate).contains(normalizePlate(plate)))
        case "unknownPlate": return truth(["car", "motorcycle", "license_plate"].contains(event.label) && event.recognizedPlate == nil)
        case "stationary":
            guard let expected = value["stationary"] as? Bool, let actual = event.stationary else { return .unknown }
            return truth(actual == expected)
        case "hasClip": return truth(event.hasClip)
        case "perRuleCooldown":
            guard let seconds = value["seconds"] as? Int else { return .unknown }
            guard let fired = lastFired[ruleID] else { return .yes }
            return truth(now.timeIntervalSince1970 - fired >= Double(seconds))
        default: return .unknown
        }
    }

    private func clearAcknowledgement() {
        for key in [
            Self.ackRevisionKey, Self.ackHashKey, Self.ackBridgeKey, Self.ackTimestampKey,
            Self.ackMACKey, Self.ackTimeZoneKey,
        ] {
            store.removeObject(forKey: key)
        }
        store.synchronize()
    }

    private static func signingInput(event: FrigateMQTTClient.Event, decision: BridgeAutomationDecision) -> String {
        [
            event.reviewID ?? "", event.reviewSeverity ?? "", event.id,
            String(decision.policyRevision), decision.policyHash, decision.ruleID, decision.branchID,
            decision.decisionID, decision.disposition.rawValue, decision.priority,
            decision.category ?? "", decision.spokenTemplate ?? "",
            canonicalVolume(decision.criticalVolume),
        ].joined(separator: "\n")
    }

    private static func sign(_ input: String, key: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: SymmetricKey(data: key))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalVolume(_ value: Double?) -> String {
        guard let value else { return "" }
        var text = String(format: "%.6f", value)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }

    private func truth(_ value: Bool) -> Truth { value ? .yes : .no }
    private func compare(_ lhs: Double, _ rhs: Double, _ operation: String) -> Bool {
        switch operation {
        case "gt": return lhs > rhs
        case "gte": return lhs >= rhs
        case "lt": return lhs < rhs
        case "lte": return lhs <= rhs
        case "eq": return lhs == rhs
        default: return false
        }
    }
    private func normalizePlate(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}

nonisolated private enum SharedAutomationKey {
    private static let service = "com.lorislab.lumen.automation-authority"
    private static let account = "decision-hmac-v1"
    private static let accessGroup = "TDV6D5L785.com.lorislab.lumen.automation"

    static func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return data
    }
}
