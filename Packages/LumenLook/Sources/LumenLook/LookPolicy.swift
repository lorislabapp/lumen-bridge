import Foundation

/// All signals for one check, gathered by `LookVerifier`.
public struct PolicyInput: Sendable {
    public var expected: LookState
    /// A reason the camera cannot be used at all (offline, privacy, moved, occluded, stale, dark).
    public var sceneIssue: UnknownReason?
    public var infrared: Bool
    public var pixels: PixelReading?
    public var classifier: (state: LookState, confidence: Double)?
    public var model: JudgeAnswer?
    /// Device-reported state at check time (Home Assistant), nil when unknown/unavailable.
    public var device: LookState?

    public init(expected: LookState, sceneIssue: UnknownReason? = nil, infrared: Bool = false, pixels: PixelReading? = nil,
                classifier: (state: LookState, confidence: Double)? = nil, model: JudgeAnswer? = nil,
                device: LookState? = nil) {
        self.expected = expected
        self.sceneIssue = sceneIssue
        self.infrared = infrared
        self.pixels = pixels
        self.classifier = classifier
        self.model = model
        self.device = device
    }
}

public struct PolicyDecision: Sendable, Equatable {
    public var outcome: LookOutcome
    public var source: LookSource
    public var confidence: Double
}

/// Deterministic rules. Never "confirmed" without a camera signal for the
/// expected state; a doubt ends in `unknown` with a reason, never in a retry.
public enum LookPolicy {
    public static let classifierConfident = 0.7
    public static let modelConfident = 0.6

    /// Ask the vision model? Only when the cheaper signals did not settle it.
    /// At night the model is unreliable on infrared pictures (ThermEval,
    /// IF-Bench): asked only to back a pixel lean, never alone.
    public static func needsModel(_ input: PolicyInput) -> Bool {
        if input.sceneIssue != nil { return false }
        let pixelConf = input.pixels?.observed == nil ? 0 : (input.pixels?.confidence ?? 0)
        if pixelConf >= PixelReading.confident, input.pixels?.blind == false { return false }
        if let c = input.classifier, c.confidence >= classifierConfident { return false }
        if input.infrared { return pixelConf >= PixelReading.leaning }
        return true
    }

    public static func decide(_ input: PolicyInput) -> PolicyDecision {
        let expected = input.expected
        if let issue = input.sceneIssue { return PolicyDecision(outcome: .unknown(issue), source: .scene, confidence: 0) }

        let pixels = input.pixels.flatMap { $0.observed == nil || $0.blind ? nil : $0 }
        let classifier = input.classifier.flatMap { $0.confidence >= classifierConfident ? $0 : nil }

        // 1. A confident pixel test.
        if let p = pixels, p.confidence >= PixelReading.confident, let seen = p.observed {
            if let c = classifier, c.state != seen {
                return PolicyDecision(outcome: .unknown(.unsure), source: .pixels, confidence: 0.5)
            }
            return seen == expected
                ? PolicyDecision(outcome: .confirmed, source: .pixels, confidence: p.confidence)
                : PolicyDecision(outcome: .contradicted(observed: seen), source: .pixels, confidence: p.confidence)
        }

        // 2. The owner's Frigate classifier for this area.
        if let c = classifier {
            if let p = pixels, p.confidence >= PixelReading.leaning, p.observed != c.state {
                return PolicyDecision(outcome: .unknown(.unsure), source: .frigateClassifier, confidence: 0.5)
            }
            return c.state == expected
                ? PolicyDecision(outcome: .confirmed, source: .frigateClassifier, confidence: c.confidence)
                : PolicyDecision(outcome: .contradicted(observed: c.state), source: .frigateClassifier, confidence: c.confidence)
        }

        let lean = pixels.flatMap { $0.confidence >= PixelReading.leaning ? $0.observed : nil }

        // 3. The vision model, checked against the pixel lean.
        if let m = input.model {
            if !m.visible || m.lookState == nil || m.confidence < modelConfident {
                return unknown(input)
            }
            let said = m.lookState!
            if input.infrared && lean != said { return PolicyDecision(outcome: .unknown(.night), source: .visionModel, confidence: 0.5) }
            if let lean, lean != said { return PolicyDecision(outcome: .unknown(.unsure), source: .visionModel, confidence: 0.5) }
            return said == expected
                ? PolicyDecision(outcome: .confirmed, source: .visionModel, confidence: m.confidence)
                : PolicyDecision(outcome: .contradicted(observed: said), source: .visionModel, confidence: m.confidence)
        }

        // 4. A pixel lean that the device's own report backs up.
        if let lean, let device = input.device, lean == device {
            let conf = pixels?.confidence ?? 0.6
            return lean == expected
                ? PolicyDecision(outcome: .confirmed, source: .pixels, confidence: conf)
                : PolicyDecision(outcome: .contradicted(observed: lean), source: .pixels, confidence: conf)
        }

        // 5. The device itself says it did not change (after its travel time).
        if let device = input.device, device != expected, lean != expected {
            return PolicyDecision(outcome: .contradicted(observed: device), source: .device, confidence: 0.6)
        }
        return unknown(input)
    }

    static func unknown(_ input: PolicyInput) -> PolicyDecision {
        let reason: UnknownReason = input.infrared ? .night : (input.pixels?.blind == true ? .tooDark : .unsure)
        return PolicyDecision(outcome: .unknown(reason), source: .scene, confidence: 0)
    }
}
