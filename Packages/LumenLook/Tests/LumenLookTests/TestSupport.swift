import CoreGraphics
import Foundation
import Network
@testable import LumenLook

/// Frames in call order, each stamped `offset` seconds after `base` (X-Frame-Time).
actor ScriptedFrames: LookFrameSource {
    enum Step { case frame(CGImage, offset: TimeInterval, timed: Bool = true), fail(LookFrameError) }
    private var steps: [Step]
    private let base: Date
    private(set) var calls = 0

    init(base: Date, _ steps: [Step]) {
        self.base = base
        self.steps = steps
    }

    func frame(camera: String, height: Int) async throws -> CameraFrame {
        calls += 1
        let step = steps.count > 1 ? steps.removeFirst() : steps[0]
        switch step {
        case .frame(let image, let offset, let timed):
            return CameraFrame(image: image, frameTime: timed ? base.addingTimeInterval(offset) : nil,
                               fetchedAt: base.addingTimeInterval(offset + 0.05))
        case .fail(let error):
            throw error
        }
    }
}

struct FixedDevice: DeviceStateReader {
    let value: LookState?
    func state(of entityID: String) async -> LookState? { value }
}

actor CountingRetrier: LookRetrier {
    private(set) var count = 0
    let allow: Bool
    init(allow: Bool = true) { self.allow = allow }
    func retry(_ request: LookRequest) async -> Bool {
        count += 1
        return allow
    }
}

actor RecordingLookNotifier: LookNotifier {
    private(set) var results: [LookResult] = []
    func deliver(_ result: LookResult, target: LookTarget) async { results.append(result) }
}

struct FixedOcclusion: OcclusionChecking {
    let boxes: [LookRect]
    func occluders(in image: CGImage) async -> [LookRect] { boxes }
}

actor StubJudge: VisualJudge {
    let answer: JudgeAnswer?
    let available: Bool
    private(set) var asked = 0
    private(set) var lastQuestion: JudgeQuestion?
    init(_ answer: JudgeAnswer?, available: Bool = true) {
        self.answer = answer
        self.available = available
    }
    func isAvailable() async -> Bool { available }
    func judge(_ question: JudgeQuestion) async throws -> JudgeAnswer {
        asked += 1
        lastQuestion = question
        guard let answer else { throw JudgeError.invalidOutput }
        return answer
    }
}

struct FixedClassifier: StateClassifierSource {
    let reading: ClassifierReading?
    func latest(camera: String, model: String) async -> ClassifierReading? { reading }
}

enum Fixture {
    static func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lumenlook-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func area(_ kind: LookDeviceKind) -> LookRect {
        switch kind {
        case .light: Scene.lamp
        case .tv: Scene.tv
        case .shutter: Scene.window
        case .door: Scene.door
        }
    }

    static func entity(_ kind: LookDeviceKind) -> String {
        switch kind {
        case .light: "light.lampe_salon"
        case .tv: "media_player.tv_salon"
        case .shutter: "cover.volets_salon"
        case .door: "cover.porte_garage"
        }
    }

    /// Scene with one device set.
    static func scene(_ kind: LookDeviceKind, _ state: LookState, base: Scene = Scene(), seed: UInt64 = 1, tvFrame: Int = 0) -> Scene {
        var s = base
        s.noiseSeed = seed
        s.tvFrame = tvFrame
        switch kind {
        case .light: s.lampOn = state == .on
        case .tv: s.tvOn = state == .on
        case .shutter: s.shutterClosed = state == .closed
        case .door: s.doorOpen = state == .open
        }
        return s
    }

    struct Run {
        var result: LookResult
        var retries: Int
        var judgeAsked: Int
        var frameCalls: Int
        var notified: [LookResult]
    }

    /// One act→look cycle with synthetic frames. `afterStates` lists the state
    /// shown at each later "after" (second entry: after the retry).
    static func run(_ kind: LookDeviceKind, from prior: LookState?, to expected: LookState, shows afterStates: [LookState],
                    base: Scene = Scene(), current: Scene? = nil, seed: UInt64 = 1, withBefore: Bool = true,
                    device: LookState? = nil, judge: StubJudge? = nil, occlusion: [LookRect] = [],
                    classifier: ClassifierReading? = nil, frigateModel: String? = nil,
                    reference: Scene? = nil, samples: [String: StateSample] = [:], steps: [ScriptedFrames.Step]? = nil,
                    allowRetry: Bool = true, root: URL? = nil, realOcclusion: Bool = false) async -> Run {
        let t0 = Date()
        let travel = kind.defaultTravelSeconds
        var script: [ScriptedFrames.Step] = []
        if let steps {
            script = steps
        } else {
            let priorScene = scene(kind, prior ?? expected.opposite, base: base, seed: seed)
            if withBefore { script.append(.frame(priorScene.image(), offset: -0.1)) }
            for (i, state) in afterStates.enumerated() {
                var s = scene(kind, state, base: current ?? base, seed: seed &+ UInt64(10 * (i + 1)), tvFrame: 10 * i + 1)
                if current == nil { s.shiftX = base.shiftX; s.shiftY = base.shiftY }
                let at = travel * Double(i + 1) + Double(i) * 2
                script.append(.frame(s.image(), offset: at))
                if kind == .tv {
                    var later = s
                    later.tvFrame += 1
                    later.noiseSeed &+= 1
                    script.append(.frame(later.image(), offset: at + 1))
                }
            }
        }
        let frames = ScriptedFrames(base: t0, script)
        let store = LookStore(root: root ?? tempRoot())
        await store.upsert(LookTarget(entityID: entity(kind), name: "Salon", kind: kind, camera: "salon", area: area(kind),
                                      samples: samples, frigateModel: frigateModel))
        if let reference { await store.setReference(entity(kind), image: reference.image()) }
        let retrier = CountingRetrier(allow: allowRetry)
        let notifier = RecordingLookNotifier()
        let verifier = LookVerifier(dependencies: .init(
            frames: frames, store: store,
            occlusion: realOcclusion ? VisionHumanOcclusion() : FixedOcclusion(boxes: occlusion),
            classifier: FixedClassifier(reading: classifier), judge: judge, device: FixedDevice(value: device),
            retrier: retrier, notifier: notifier, sleep: { _ in }))
        let request = LookRequest(entityID: entity(kind), expected: expected, prior: prior, commandAt: t0,
                                  language: "fr")
        if withBefore && steps == nil {
            await verifier.prepare(request)
            await verifier.waitForBefore(entity(kind))
        }
        let task = await verifier.verify(request)
        let result = await task!.value!
        return Run(result: result, retries: await retrier.count, judgeAsked: await judge?.asked ?? 0,
                   frameCalls: await frames.calls, notified: await notifier.results)
    }
}

/// Minimal HTTP/1.1 server on 127.0.0.1 for the llama-server client tests.
final class StubHTTPServer: @unchecked Sendable {
    struct Request: Sendable { var method: String; var path: String; var body: Data }
    typealias Handler = @Sendable (Request) -> (Int, Data)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "stub-http")
    private let lock = NSLock()
    private var _requests: [Request] = []
    private let handler: Handler
    var requests: [Request] { lock.withLock { _requests } }
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) throws {
        self.handler = handler
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws {
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        for await port in ready.stream { self.port = port; break }
    }

    func stop() { listener.cancel() }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        let buffer = Buffer()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, _ in
                guard let self else { return }
                if let data { buffer.data.append(data) }
                if let request = Self.parse(buffer.data) {
                    self.lock.withLock { self._requests.append(request) }
                    let (status, body) = self.handler(request)
                    var head = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
                    head += "Connection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                } else if !done {
                    readMore()
                } else {
                    connection.cancel()
                }
            }
        }
        readMore()
    }

    final class Buffer: @unchecked Sendable { var data = Data() }

    static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var length = 0
        for line in lines where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }
}
