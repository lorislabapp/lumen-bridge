import CryptoKit
import Foundation

// The assistant's tool model, written in LorisAI's vocabulary (LorisFoundation
// docs/LorisAI.md) so it can move onto `AIToolGate` once LorisAI qualifies
// (its 2026-10-23 eval is NO-GO). Same frozen raw values, same rules:
// - every tool declares an effect; anything but `read-only` needs a proposal;
// - receipts are HMAC-bound to the exact proposal, single-use, and expire on a
//   monotonic clock;
// - the model never triggers effects: it only returns calls the policy checks.

/// Mirrors `AIToolEffect` (raw values frozen, kebab-case).
public struct ToolEffect: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let readOnly = ToolEffect(rawValue: "read-only")
    public static let write = ToolEffect(rawValue: "write")
    public static let destructive = ToolEffect(rawValue: "destructive")

    /// LorisAI rule: any effect other than read-only (or unknown) needs confirmation.
    public var needsConfirmationInLorisAI: Bool { self != .readOnly }
}

/// Safety tier of one action, decided by code (never by the LLM).
public enum ActionTier: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Lights, TV/media, fans, plugs, scenes, shutters/blinds, status questions.
    case t0 = 0
    /// Thermostat/heating, camera privacy.
    case t1 = 1
    /// Locks, alarm, garage/gate: never executed from camera audio; proposal only.
    case t2 = 2

    public static func < (a: ActionTier, b: ActionTier) -> Bool { a.rawValue < b.rawValue }

    /// LorisAI effect for this tier. T0/T1 are `write`, but the Hub runs them
    /// on the policy's say-so (the voice request is the confirmation, EDPB
    /// 02/2021 §"execution of the request"); T2 is `destructive` and always
    /// goes through a proposal + receipt.
    public var effect: ToolEffect { self == .t2 ? .destructive : .write }
}

/// The few typed tools the LLM may call. Kept to a handful (research: a JSON
/// schema guarantees syntax only, not the right tool).
public enum AssistantToolName: String, Codable, Sendable, CaseIterable {
    case controlDevice = "control_device"
    case queryDevice = "query_device"
    case noAction = "no_action"

    public var effect: ToolEffect {
        switch self {
        case .controlDevice: .write
        case .queryDevice, .noAction: .readOnly
        }
    }
}

/// A plan the policy turned into a pending proposal (T2). Nothing runs until a
/// matching receipt comes back from the owner's iPhone (Face ID).
public struct ActionProposal: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let plan: ActionPlan
    public let effect: ToolEffect
    public let createdAt: Date
    /// Wall-clock expiry, for display and the push. The binding check uses a monotonic deadline.
    public let expiresAt: Date
    public let camera: String
    public let speaker: String?

    public init(id: UUID = UUID(), plan: ActionPlan, effect: ToolEffect, createdAt: Date, expiresAt: Date,
                camera: String, speaker: String?) {
        self.id = id
        self.plan = plan
        self.effect = effect
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.camera = camera
        self.speaker = speaker
    }

    /// Canonical bytes the receipt is bound to.
    var bindingData: Data {
        var parts = [id.uuidString, effect.rawValue, plan.action.rawValue, camera]
        parts.append(contentsOf: plan.targets.map(\.entityID).sorted())
        if let v = plan.value { parts.append(String(format: "%.2f", v)) }
        parts.append(String(Int(expiresAt.timeIntervalSince1970)))
        return Data(parts.joined(separator: "|").utf8)
    }
}

/// What the iPhone sends back after Face ID: an HMAC over the proposal.
public struct ConfirmationReceipt: Sendable, Equatable, Codable {
    public let proposalID: UUID
    public let mac: Data
    public init(proposalID: UUID, mac: Data) {
        self.proposalID = proposalID
        self.mac = mac
    }
}

public enum ProposalError: Error, Equatable, Sendable {
    case unknownProposal
    case expired
    case alreadyUsed
    case badReceipt
}

/// Pending T2 proposals. Receipts are single-use and checked against a
/// monotonic deadline (a wall-clock change cannot revive a proposal).
public actor ProposalBook {
    private struct Entry {
        let proposal: ActionProposal
        let deadline: ContinuousClock.Instant
    }

    public static let lifetime: Duration = .seconds(30)
    private let key: SymmetricKey
    private let clock = ContinuousClock()
    private var pending: [UUID: Entry] = [:]
    private var used: Set<UUID> = []

    /// `key` is the Hub's pairing key with the owner's iPhone (Keychain in the app).
    public init(key: SymmetricKey) { self.key = key }

    public func add(_ proposal: ActionProposal, lifetime: Duration = ProposalBook.lifetime) {
        prune()
        pending[proposal.id] = Entry(proposal: proposal, deadline: clock.now.advanced(by: lifetime))
    }

    public var all: [ActionProposal] {
        prune()
        return pending.values.map(\.proposal).sorted { $0.createdAt > $1.createdAt }
    }

    public func dismiss(_ id: UUID) { pending[id] = nil }

    /// The MAC the iPhone computes after Face ID (same key, same binding).
    public nonisolated static func sign(_ proposal: ActionProposal, key: SymmetricKey) -> ConfirmationReceipt {
        let mac = HMAC<SHA256>.authenticationCode(for: proposal.bindingData, using: key)
        return ConfirmationReceipt(proposalID: proposal.id, mac: Data(mac))
    }

    /// Consumes the proposal (at most one dispatch) and returns it when the receipt is valid.
    public func redeem(_ receipt: ConfirmationReceipt) throws -> ActionProposal {
        if used.contains(receipt.proposalID) { throw ProposalError.alreadyUsed }
        guard let entry = pending[receipt.proposalID] else { throw ProposalError.unknownProposal }
        guard clock.now < entry.deadline else {
            pending[receipt.proposalID] = nil
            throw ProposalError.expired
        }
        guard HMAC<SHA256>.isValidAuthenticationCode(receipt.mac, authenticating: entry.proposal.bindingData,
                                                     using: key) else { throw ProposalError.badReceipt }
        pending[receipt.proposalID] = nil
        used.insert(receipt.proposalID)
        return entry.proposal
    }

    private func prune() {
        let now = clock.now
        pending = pending.filter { $0.value.deadline > now }
    }
}
