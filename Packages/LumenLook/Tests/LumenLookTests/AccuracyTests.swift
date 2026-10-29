import Foundation
import Testing
@testable import LumenLook

/// The synthetic set: every device × both directions × success/failure ×
/// day/night × with/without a "before" frame × 6 noise seeds. Reports
/// accuracy and abstentions; fails on any wrong "confirmed".
@Suite("Synthetic accuracy and latency", .serialized)
struct AccuracyTests {
    struct Tally { var right = 0, unknown = 0, wrongConfirm = 0, wrongContradict = 0, total = 0 }

    @Test func syntheticSet() async {
        var tallies: [String: Tally] = [:]
        var totals: [Double] = []
        var failures: [String] = []
        for kind in LookDeviceKind.allCases {
            let (pos, neg) = kind.states
            for night in [false, true] {
                for withBefore in [true, false] {
                    for (from, to) in [(neg, pos), (pos, neg)] {
                        for worked in [true, false] {
                            for seed in UInt64(1)...6 {
                                var base = Scene()
                                base.night = night
                                let shown = worked ? to : from
                                let run = await Fixture.run(kind, from: withBefore ? from : nil, to: to, shows: [shown],
                                                            base: base, seed: seed * 31, withBefore: withBefore, allowRetry: false)
                                let key = "\(kind.rawValue) \(night ? "night" : "day")"
                                var t = tallies[key, default: Tally()]
                                t.total += 1
                                switch run.result.outcome {
                                case .confirmed:
                                    if worked { t.right += 1 } else {
                                        t.wrongConfirm += 1
                                        failures.append("\(key) \(from)->\(to) worked=\(worked) before=\(withBefore) seed=\(seed): \(run.result.evidence)")
                                    }
                                case .contradicted:
                                    if worked {
                                        t.wrongContradict += 1
                                        failures.append("\(key) \(from)->\(to) worked=\(worked) before=\(withBefore) seed=\(seed) CONTRA: \(run.result.evidence)")
                                    } else { t.right += 1 }
                                case .unknown:
                                    t.unknown += 1
                                }
                                tallies[key] = t
                                totals.append(run.result.timing.totalMs)
                            }
                        }
                    }
                }
            }
        }
        print("LOOK-ACCURACY kind/light | right | unknown | wrong-confirmed | wrong-contradicted | total")
        var all = Tally()
        for key in tallies.keys.sorted() {
            let t = tallies[key]!
            all.right += t.right; all.unknown += t.unknown; all.wrongConfirm += t.wrongConfirm
            all.wrongContradict += t.wrongContradict; all.total += t.total
            print("LOOK-ACCURACY \(key) | \(t.right) | \(t.unknown) | \(t.wrongConfirm) | \(t.wrongContradict) | \(t.total)")
        }
        print("LOOK-ACCURACY ALL | \(all.right) | \(all.unknown) | \(all.wrongConfirm) | \(all.wrongContradict) | \(all.total)")
        for f in failures.prefix(30) { print("LOOK-FAIL \(f)") }
        totals.sort()
        print("LOOK-LATENCY pixel path (no pose ref, stub occlusion) median \(totals[totals.count / 2]) ms, p95 \(totals[Int(Double(totals.count) * 0.95)]) ms")
        #expect(all.wrongConfirm == 0)
        #expect(Double(all.wrongContradict) / Double(all.total) < 0.02)
        // Day, with a before frame, must almost always answer.
        let dayAnswered = tallies.filter { $0.key.hasSuffix("day") }.values.reduce(0) { $0 + $1.right }
        let dayTotal = tallies.filter { $0.key.hasSuffix("day") }.values.reduce(0) { $0 + $1.total }
        #expect(Double(dayAnswered) / Double(dayTotal) > 0.6)
    }

    @Test func latencyFullPath() async {
        // Real Vision: camera-moved (registration + feature print) and person detection.
        var full: [LookTiming] = []
        for seed in UInt64(1)...8 {
            let run = await Fixture.run(.shutter, from: .open, to: .closed, shows: [.closed], seed: seed, reference: Scene(),
                                        realOcclusion: true)
            #expect(run.result.outcome == .confirmed)
            full.append(run.result.timing)
        }
        let judge = StubJudge(JudgeAnswer(visible: true, state: "open", changed: "unknown", confidence: 0.9))
        let model = await Fixture.run(.door, from: nil, to: .open, shows: [.open], withBefore: false, judge: judge, reference: Scene(),
                                      realOcclusion: true)
        func med(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
        print(String(format: "LOOK-LATENCY full path (warm, median of 7 after first): fetch %.1f, scene+pose+people %.1f, pixels %.1f, total %.1f ms; first run total %.1f ms",
                     med(full.dropFirst().map(\.fetchMs)), med(full.dropFirst().map(\.sceneMs)), med(full.dropFirst().map(\.pixelsMs)),
                     med(full.dropFirst().map(\.totalMs)), full[0].totalMs))
        print(String(format: "LOOK-LATENCY with stub model: model step %.1f ms, total %.1f ms", model.result.timing.modelMs,
                     model.result.timing.totalMs))
    }
}
