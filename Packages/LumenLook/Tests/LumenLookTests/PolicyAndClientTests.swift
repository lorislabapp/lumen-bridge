import CoreGraphics
import Foundation
import Testing
@testable import LumenLook

@Suite("Look policy")
struct PolicyTests {
    func pixels(_ s: LookState?, _ c: Double, blind: Bool = false) -> PixelReading {
        PixelReading(observed: s, confidence: c, changed: nil, blind: blind, evidence: "")
    }

    @Test func sceneIssueWins() {
        let d = LookPolicy.decide(PolicyInput(expected: .on, sceneIssue: .privacyMode, pixels: pixels(.on, 0.95), device: .on))
        #expect(d.outcome == .unknown(.privacyMode))
    }

    @Test func confidentPixels() {
        #expect(LookPolicy.decide(PolicyInput(expected: .on, pixels: pixels(.on, 0.9))).outcome == .confirmed)
        #expect(LookPolicy.decide(PolicyInput(expected: .on, pixels: pixels(.off, 0.9))).outcome == .contradicted(observed: .off))
    }

    @Test func deviceAloneNeverConfirms() {
        // The device says "on" but the camera saw nothing useful: not confirmed.
        let d = LookPolicy.decide(PolicyInput(expected: .on, pixels: pixels(nil, 0.5), device: .on))
        #expect(d.outcome == .unknown(.unsure))
        let night = LookPolicy.decide(PolicyInput(expected: .closed, infrared: true, pixels: pixels(nil, 0.5), device: .closed))
        #expect(night.outcome == .unknown(.night))
    }

    @Test func deviceReportsFailure() {
        let d = LookPolicy.decide(PolicyInput(expected: .on, pixels: pixels(nil, 0.5), device: .off))
        #expect(d.outcome == .contradicted(observed: .off))
        #expect(d.source == .device)
    }

    @Test func leanPlusDeviceAgreement() {
        #expect(LookPolicy.decide(PolicyInput(expected: .on, pixels: pixels(.on, 0.7), device: .on)).outcome == .confirmed)
        #expect(LookPolicy.decide(PolicyInput(expected: .on, pixels: pixels(.on, 0.7))).outcome == .unknown(.unsure))
    }

    @Test func blindPixelsIgnored() {
        let d = LookPolicy.decide(PolicyInput(expected: .on, pixels: pixels(.on, 0.95, blind: true)))
        #expect(d.outcome == .unknown(.tooDark))
    }

    @Test func classifierAgainstPixels() {
        let d = LookPolicy.decide(PolicyInput(expected: .open, pixels: pixels(.closed, 0.9), classifier: (.open, 0.9)))
        #expect(d.outcome == .unknown(.unsure))
        let c = LookPolicy.decide(PolicyInput(expected: .open, pixels: pixels(nil, 0.5), classifier: (.open, 0.9)))
        #expect(c.outcome == .confirmed)
        #expect(c.source == .frigateClassifier)
    }

    @Test func modelRules() {
        let yes = JudgeAnswer(visible: true, state: "on", changed: "yes", confidence: 0.85)
        #expect(LookPolicy.decide(PolicyInput(expected: .on, pixels: pixels(nil, 0.5), model: yes)).outcome == .confirmed)
        // Model disagrees with a pixel lean → unsure.
        #expect(LookPolicy.decide(PolicyInput(expected: .on, pixels: pixels(.off, 0.7), model: yes)).outcome == .unknown(.unsure))
        // Night: model alone is not enough.
        #expect(LookPolicy.decide(PolicyInput(expected: .on, infrared: true, pixels: pixels(nil, 0.5), model: yes)).outcome
                == .unknown(.night))
        #expect(LookPolicy.decide(PolicyInput(expected: .on, infrared: true, pixels: pixels(.on, 0.7), model: yes)).outcome
                == .confirmed)
        let hidden = JudgeAnswer(visible: false, state: "unknown", changed: "unknown", confidence: 0.9)
        #expect(LookPolicy.decide(PolicyInput(expected: .on, pixels: pixels(nil, 0.5), model: hidden)).outcome == .unknown(.unsure))
        let weak = JudgeAnswer(visible: true, state: "on", changed: "yes", confidence: 0.4)
        #expect(LookPolicy.decide(PolicyInput(expected: .on, pixels: pixels(nil, 0.5), model: weak)).outcome == .unknown(.unsure))
    }

    @Test func modelMustBeConsistentWithThePrior() {
        // Live failure: door really open, expected closed, model "closed" but "changed: unknown".
        let yesBias = JudgeAnswer(visible: true, state: "closed", changed: "unknown", confidence: 0.95)
        #expect(LookPolicy.decide(PolicyInput(expected: .closed, pixels: pixels(nil, 0.5), model: yesBias, prior: .open)).outcome
                == .unknown(.unsure))
        let moved = JudgeAnswer(visible: true, state: "closed", changed: "yes", confidence: 0.95)
        #expect(LookPolicy.decide(PolicyInput(expected: .closed, pixels: pixels(nil, 0.5), model: moved, prior: .open)).outcome
                == .confirmed)
        // "Still open" but "changed: yes" contradicts itself.
        let odd = JudgeAnswer(visible: true, state: "open", changed: "yes", confidence: 0.95)
        #expect(LookPolicy.decide(PolicyInput(expected: .closed, pixels: pixels(nil, 0.5), model: odd, prior: .open)).outcome
                == .unknown(.unsure))
        let stuck = JudgeAnswer(visible: true, state: "open", changed: "no", confidence: 0.95)
        #expect(LookPolicy.decide(PolicyInput(expected: .closed, pixels: pixels(nil, 0.5), model: stuck, prior: .open)).outcome
                == .contradicted(observed: .open))
    }

    @Test func whenToAskTheModel() {
        #expect(!LookPolicy.needsModel(PolicyInput(expected: .on, pixels: pixels(.on, 0.9))))
        #expect(LookPolicy.needsModel(PolicyInput(expected: .on, pixels: pixels(.on, 0.7))))
        #expect(!LookPolicy.needsModel(PolicyInput(expected: .on, sceneIssue: .occluded)))
        #expect(!LookPolicy.needsModel(PolicyInput(expected: .on, infrared: true, pixels: pixels(nil, 0.5))))
        #expect(LookPolicy.needsModel(PolicyInput(expected: .on, infrared: true, pixels: pixels(.on, 0.65))))
        #expect(!LookPolicy.needsModel(PolicyInput(expected: .on, pixels: pixels(nil, 0.5), classifier: (.on, 0.9))))
    }

    @Test func haStates() {
        #expect(LookState(homeAssistant: "playing") == .on)
        #expect(LookState(homeAssistant: "standby") == .off)
        #expect(LookState(homeAssistant: "closed") == .closed)
        #expect(LookState(homeAssistant: "opening") == nil)
        #expect(LookState(homeAssistant: "unavailable") == nil)
    }

    @Test func rectMath() {
        let r = LookRect(x: 0.9, y: -0.1, width: 0.3, height: 0.5).clamped
        #expect(r.x + r.width <= 1.0001 && r.y >= 0)
        #expect(LookRect(x: 0, y: 0, width: 0.5, height: 0.5).intersection(LookRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)) == 0.0625)
        #expect(SceneJudge.occluded(LookRect(x: 0, y: 0, width: 0.2, height: 0.2), by: [LookRect(x: 0.1, y: 0, width: 0.2, height: 0.2)]))
        #expect(!SceneJudge.occluded(LookRect(x: 0, y: 0, width: 0.2, height: 0.2), by: [LookRect(x: 0.18, y: 0, width: 0.2, height: 0.2)]))
    }

    @Test func frameTimeHeader() {
        #expect(JPEG.frameTime(header: "1761735600.123")?.timeIntervalSince1970 == 1761735600.123)
        #expect(JPEG.frameTime(header: "abc") == nil)
        #expect(JPEG.frameTime(header: nil) == nil)
    }
}

@Suite("llama-server vision client")
struct JudgeClientTests {
    static func reply(_ content: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    func question() -> JudgeQuestion {
        let before = Fixture.scene(.shutter, .open).image().crop(Scene.window)!
        let after = Fixture.scene(.shutter, .closed).image().crop(Scene.window)!
        return JudgeQuestion(kind: .shutter, deviceName: "Volets salon", expected: .closed, prior: .open, before: before,
                             after: after, infrared: false)
    }

    @Test func schemaConstrainedRequestAndAnswer() async throws {
        let server = try StubHTTPServer { request in
            if request.path == "/props" { return (200, Data(#"{"modalities":{"vision":true}}"#.utf8)) }
            return (200, Self.reply(#"{"visible":true,"state":"closed","changed":"yes","confidence":0.91}"#))
        }
        try await server.start()
        defer { server.stop() }
        let judge = LlamaServerJudge(baseURL: server.baseURL)
        #expect(await judge.isAvailable())
        let answer = try await judge.judge(question())
        #expect(answer == JudgeAnswer(visible: true, state: "closed", changed: "yes", confidence: 0.91))

        let post = try #require(server.requests.first { $0.method == "POST" })
        #expect(post.path == "/v1/chat/completions")
        let body = try #require(try JSONSerialization.jsonObject(with: post.body) as? [String: Any])
        #expect(body["temperature"] as? Int == 0)
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
        let props = try #require(schema["properties"] as? [String: Any])
        #expect((props["state"] as? [String: Any])?["enum"] as? [String] == ["open", "closed", "unknown"])
        // Two cropped pictures, before then after, as data URLs.
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.last?["content"] as? [[String: Any]])
        let images = content.filter { $0["type"] as? String == "image_url" }
        #expect(images.count == 2)
        let url = (images.first?["image_url"] as? [String: Any])?["url"] as? String ?? ""
        #expect(url.hasPrefix("data:image/jpeg;base64,"))
    }

    @Test func outOfSchemaAnswerRejected() async throws {
        let server = try StubHTTPServer { _ in
            (200, Self.reply(#"{"visible":true,"state":"on","changed":"yes","confidence":0.9}"#))
        }
        try await server.start()
        defer { server.stop() }
        await #expect(throws: JudgeError.invalidOutput) { try await LlamaServerJudge(baseURL: server.baseURL).judge(question()) }
    }

    @Test func emptyBodyRejected() async throws {
        // What brew Ollama does with a schema: an empty answer.
        let server = try StubHTTPServer { _ in (200, Self.reply("")) }
        try await server.start()
        defer { server.stop() }
        await #expect(throws: JudgeError.invalidOutput) { try await LlamaServerJudge(baseURL: server.baseURL).judge(question()) }
    }

    @Test func textOnlyModelIsNotAvailable() async throws {
        let server = try StubHTTPServer { _ in (200, Data(#"{"modalities":{"vision":false}}"#.utf8)) }
        try await server.start()
        defer { server.stop() }
        #expect(await !LlamaServerJudge(baseURL: server.baseURL).isAvailable())
    }

    @Test func downServerIsNotAvailable() async {
        // Port 9 (discard) on loopback: nothing listens.
        let judge = LlamaServerJudge(baseURL: URL(string: "http://127.0.0.1:9")!)
        #expect(await !judge.isAvailable())
    }

    @Test func serverErrorStatus() async throws {
        let server = try StubHTTPServer { _ in (500, Data("{}".utf8)) }
        try await server.start()
        defer { server.stop() }
        await #expect(throws: JudgeError.badStatus(500)) { try await LlamaServerJudge(baseURL: server.baseURL).judge(question()) }
    }
}

@Suite("Look store")
struct StoreTests {
    @Test func targetsPersistAndAreaChangeForgetsLooks() async {
        let root = Fixture.tempRoot()
        let store = LookStore(root: root)
        let f = FeatureExtractor.features(of: Fixture.scene(.light, .on).image(), area: Scene.lamp)!
        await store.upsert(LookTarget(entityID: "light.a", name: "A", kind: .light, camera: "salon", area: Scene.lamp))
        await store.learn("light.a", state: .on, infrared: false, features: f)
        let reopened = LookStore(root: root)
        #expect(await reopened.target("light.a")?.samples.count == 1)
        var moved = await reopened.target("light.a")!
        moved.area = LookRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        await reopened.upsert(moved)
        #expect(await reopened.target("light.a")?.samples.isEmpty == true)
    }

    @Test func proofsArePrunedAndNamesChecked() async throws {
        let root = Fixture.tempRoot()
        let store = LookStore(root: root, proofRetention: 3600)
        let name = try #require(await store.saveProof(Fixture.scene(.tv, .on).image()))
        #expect(await store.proof(name) != nil)
        #expect(await store.proof("../targets.json") == nil)
        await store.prune(now: Date().addingTimeInterval(7200))
        #expect(await store.proof(name) == nil)
    }

    @Test func referenceRoundTrip() async {
        let root = Fixture.tempRoot()
        let store = LookStore(root: root)
        await store.upsert(LookTarget(entityID: "cover.v", name: "V", kind: .shutter, camera: "salon", area: Scene.window))
        await store.setReference("cover.v", image: Scene().image())
        let reopened = LookStore(root: root)
        let ref = await reopened.reference(for: "cover.v")
        #expect(ref?.width == 640)
    }
}
