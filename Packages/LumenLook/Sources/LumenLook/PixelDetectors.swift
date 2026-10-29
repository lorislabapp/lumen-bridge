import Foundation

/// Everything the pixel test sees for one check.
public struct PixelEvidence: Sendable {
    /// Area just before the command (nil when no clean "before" frame).
    public var before: ROIFeatures?
    /// Area at end of travel.
    public var after: ROIFeatures
    /// Area ~1 s later (TV: is the picture moving?).
    public var afterLater: ROIFeatures?
    public var beforeScene: SceneFeatures?
    public var afterScene: SceneFeatures
    public var area: LookRect
    /// Device-reported state before the command.
    public var prior: LookState?

    public init(before: ROIFeatures?, after: ROIFeatures, afterLater: ROIFeatures? = nil, beforeScene: SceneFeatures? = nil,
                afterScene: SceneFeatures, area: LookRect, prior: LookState? = nil) {
        self.before = before
        self.after = after
        self.afterLater = afterLater
        self.beforeScene = beforeScene
        self.afterScene = afterScene
        self.area = area
        self.prior = prior
    }
}

public struct PixelReading: Sendable, Equatable {
    /// Most likely state, nil when there is no usable signal at all.
    public var observed: LookState?
    /// 0.5 = coin toss … 1 = certain.
    public var confidence: Double
    /// The area changed between before and after (nil: no before frame).
    public var changed: Bool?
    /// The area is too flat/dark to show anything.
    public var blind: Bool
    public var evidence: String

    public static let confident = 0.8
    public static let leaning = 0.6
}

/// One piece of evidence for a state, combined in log-odds.
struct Vote {
    let state: LookState
    let confidence: Double
    let why: String
}

/// Tier 0: brightness, texture, stripes and before/after change in the area.
/// Thresholds were set on the synthetic set (Tests/LumenLookTests) and are
/// deliberately conservative: a doubt goes to the next tier, never to "confirmed".
public enum PixelDetector {
    public static func read(_ kind: LookDeviceKind, _ e: PixelEvidence, samples: [String: StateSample] = [:]) -> PixelReading {
        let ir = e.afterScene.isInfrared
        let (pos, neg) = kind.states
        var votes: [Vote] = []
        var notes: [String] = []
        // A flat dark area hides slats and door edges. For lights and screens,
        // dark is itself the answer ("off"), so they are never "blind".
        let blind = (kind == .shutter || kind == .door) && e.after.stdLuma < 3 && (e.after.meanLuma < 25 || ir)

        // 1. Before/after change, read against the prior state.
        var changed: Bool?
        if let before = e.before {
            let roi = before.change(to: e.after)
            let outside = e.beforeScene.map { $0.changeOutside(e.area, to: e.afterScene) } ?? 0
            let isChange = roi > 9 && roi > 2.5 * outside
            let isSteady = roi < 4
            changed = isChange ? true : (isSteady ? false : nil)
            notes.append("change \(fmt(roi))/\(fmt(outside))")
            if let prior = e.prior, kind.states.positive == prior || kind.states.negative == prior {
                // A binary device seen changing from a known state is in the other one;
                // an untouched picture after the travel time means nothing happened.
                if isChange {
                    let strong = roi > 20 && roi > 4 * outside
                    votes.append(Vote(state: prior.opposite, confidence: strong ? 0.86 : 0.76, why: "changed from \(prior.rawValue)"))
                }
                if isSteady {
                    let strong = roi < 2.5 && outside < 3
                    votes.append(Vote(state: prior, confidence: strong ? 0.84 : 0.7, why: "still \(prior.rawValue)"))
                }
            }
        }

        // 2. Kind-specific appearance.
        switch kind {
        case .light: votes += light(e, ir: ir, notes: &notes)
        case .tv: votes += tv(e, notes: &notes)
        case .shutter: votes += shutter(e, blind: blind, notes: &notes)
        case .door: break
        }

        // 3. Learned looks for this lighting (calibration from earlier confirmed checks).
        if let p = samples[StateSample.key(pos, infrared: ir)], let n = samples[StateSample.key(neg, infrared: ir)] {
            let dp = distance(e.after, p.features, kind: kind), dn = distance(e.after, n.features, kind: kind)
            let margin = abs(dp - dn) / max(dp + dn, 1e-6)
            // Both far away: the scene changed (furniture, season); trust less.
            let far = min(dp, dn) > 2.5
            let conf = min(0.95, 0.55 + 0.45 * margin) - (far ? 0.15 : 0)
            if conf > 0.55 { votes.append(Vote(state: dp < dn ? pos : neg, confidence: conf, why: "learned look")) }
            notes.append("learned \(fmt(dp))/\(fmt(dn))")
        }

        let evidence = notes.joined(separator: ", ")
        guard !votes.isEmpty else {
            return PixelReading(observed: nil, confidence: 0.5, changed: changed, blind: blind, evidence: evidence)
        }
        // Log-odds sum: agreeing signals strengthen, disagreeing ones cancel.
        var logit = 0.0
        for v in votes {
            let c = min(max(v.confidence, 0.5), 0.97)
            logit += (v.state == pos ? 1 : -1) * log(c / (1 - c))
        }
        let p = 1 / (1 + exp(-logit))
        let observed = p >= 0.5 ? pos : neg
        let why = votes.map { "\($0.why)→\($0.state.rawValue)" }.joined(separator: "; ")
        return PixelReading(observed: observed, confidence: max(p, 1 - p), changed: changed, blind: blind,
                            evidence: evidence + (why.isEmpty ? "" : " | " + why))
    }

    static func light(_ e: PixelEvidence, ir: Bool, notes: inout [String]) -> [Vote] {
        var votes: [Vote] = []
        let a = e.after
        if let b = e.before {
            let delta = a.meanLuma - b.meanLuma
            let rel = delta / max(b.meanLuma, 20)
            notes.append("brightness \(Int(b.meanLuma))→\(Int(a.meanLuma))")
            if delta > 10 && rel > 0.2 {
                votes.append(Vote(state: .on, confidence: min(0.95, 0.65 + delta / 120), why: "brighter"))
            } else if delta < -10 && rel < -0.15 {
                votes.append(Vote(state: .off, confidence: min(0.95, 0.65 - delta / 120), why: "darker"))
            }
        } else {
            notes.append("brightness \(Int(a.meanLuma))")
        }
        // Absolute look: a lit lamp saturates; an unlit corner without IR is dark.
        if a.meanLuma > 150 && a.brightFraction > 0.25 {
            votes.append(Vote(state: .on, confidence: 0.66, why: "bright"))
        } else if !ir && a.meanLuma < 30 {
            votes.append(Vote(state: .off, confidence: 0.64, why: "dark"))
        }
        return votes
    }

    static func tv(_ e: PixelEvidence, notes: inout [String]) -> [Vote] {
        let a = e.after
        let temporal = e.afterLater.map { a.change(to: $0) }
        func s(_ x: Double) -> Double { 1 / (1 + exp(-x)) }
        // A lit screen is brighter and textured; a moving picture changes frame to frame.
        var score = 0.35 * s((a.meanLuma - 45) / 10) + 0.25 * s((a.stdLuma - 18) / 5)
        if let temporal {
            score += 0.4 * s((temporal - 3) / 0.8)
        } else {
            score = score / 0.6
        }
        notes.append("screen \(Int(a.meanLuma))±\(Int(a.stdLuma)) motion \(temporal.map(fmt) ?? "-")")
        var votes = [Vote(state: score >= 0.5 ? .on : .off, confidence: 0.5 + abs(score - 0.5), why: "screen")]
        if let b = e.before {
            let delta = a.meanLuma - b.meanLuma
            if delta > 15 { votes.append(Vote(state: .on, confidence: min(0.92, 0.65 + delta / 150), why: "screen lit up")) }
            if delta < -15 { votes.append(Vote(state: .off, confidence: min(0.92, 0.65 - delta / 150), why: "screen went dark")) }
        }
        return votes
    }

    static func shutter(_ e: PixelEvidence, blind: Bool, notes: inout [String]) -> [Vote] {
        let a = e.after
        notes.append("slats \(fmt(a.stripeScore)) h-edges \(fmt(a.horizontalEdgeRatio))")
        guard !blind else { return [] }
        if a.stripeScore > 0.45 && a.horizontalEdgeRatio > 0.6 {
            return [Vote(state: .closed, confidence: min(0.93, 0.6 + (a.stripeScore - 0.45)), why: "slats")]
        }
        if a.stripeScore < 0.25 && a.stdLuma > 8 {
            return [Vote(state: .open, confidence: 0.7, why: "no slats")]
        }
        return []
    }

    /// Distance between two looks of the same area (≈ 1 per clear difference).
    static func distance(_ a: ROIFeatures, _ b: ROIFeatures, kind: LookDeviceKind) -> Double {
        var d = abs(a.meanLuma - b.meanLuma) / 25 + a.change(to: b) / 30 + abs(a.stdLuma - b.stdLuma) / 20
        if kind == .shutter { d += abs(a.stripeScore - b.stripeScore) * 3 }
        return d
    }

    static func fmt(_ x: Double) -> String { String(format: "%.1f", x) }
}
