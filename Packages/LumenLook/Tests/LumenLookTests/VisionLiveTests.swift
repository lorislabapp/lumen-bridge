import Foundation
import Testing
@testable import LumenLook

/// Live vision model (llama-server + Qwen3-VL + mmproj):
/// `LUMEN_LOOK_VLM_URL=http://127.0.0.1:8012 swift test --filter VisionLive`.
/// Skipped with a message when nothing answers. Synthetic crops only: this
/// measures schema compliance and latency, not real-camera accuracy.
@Suite("VisionLive", .serialized)
struct VisionLiveTests {
    static let url = URL(string: ProcessInfo.processInfo.environment["LUMEN_LOOK_VLM_URL"] ?? "http://127.0.0.1:8012")!

    @Test func liveSchemaAccuracyAndLatency() async throws {
        let judge = LlamaServerJudge(baseURL: Self.url, timeout: 60)
        guard await judge.isAvailable() else {
            print("VISION-LIVE skipped: no vision llama-server at \(Self.url.absoluteString)")
            return
        }
        var right = 0, unknown = 0, wrong = 0, total = 0
        var times: [Double] = []
        let clock = ContinuousClock()
        for kind in LookDeviceKind.allCases {
            let (pos, neg) = kind.states
            for night in [false, true] {
                for (from, to) in [(neg, pos), (pos, neg)] {
                    for worked in [true, false] {
                        var base = Scene()
                        base.night = night
                        let shown = worked ? to : from
                        let area = Fixture.area(kind).expanded(by: 0.25)
                        let before = Fixture.scene(kind, from, base: base, seed: 3).image().crop(area)
                        let after = Fixture.scene(kind, shown, base: base, seed: 9, tvFrame: 5).image().crop(area)!
                        let q = JudgeQuestion(kind: kind, deviceName: "Salon", expected: to, prior: from, before: before,
                                              after: after, infrared: night)
                        let start = clock.now
                        let answer: JudgeAnswer
                        do { answer = try await judge.judge(q) } catch {
                            print("VISION-LIVE \(kind) night=\(night) \(from)->\(to) shown=\(shown): ERROR \(error)")
                            wrong += 1; total += 1
                            continue
                        }
                        let ms = Double(start.duration(to: clock.now).components.attoseconds) / 1e15
                            + Double(start.duration(to: clock.now).components.seconds) * 1000
                        times.append(ms)
                        total += 1
                        let said = answer.visible && answer.confidence >= LookPolicy.modelConfident ? answer.lookState : nil
                        if said == nil { unknown += 1 } else if said == shown { right += 1 } else { wrong += 1 }
                        print(String(format: "VISION-LIVE %@ night=%d %@->%@ shown=%@: %@ conf %.2f visible %d changed %@ (%.0f ms)",
                                     kind.rawValue, night ? 1 : 0, from.rawValue, to.rawValue, shown.rawValue, answer.state,
                                     answer.confidence, answer.visible ? 1 : 0, answer.changed, ms))
                    }
                }
            }
        }
        times.sort()
        print("VISION-LIVE right \(right) unknown \(unknown) wrong \(wrong) of \(total); latency median \(Int(times[times.count / 2])) ms, max \(Int(times.last ?? 0)) ms, first \(Int(times.first ?? 0)) ms (sorted min)")
        #expect(total == 32)
    }
}
