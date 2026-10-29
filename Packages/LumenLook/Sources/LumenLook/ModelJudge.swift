import CoreGraphics
import Foundation

// MARK: Frigate state classification (tier 0b)

/// Latest output of a Frigate 0.18 state-classification model
/// (MQTT `frigate/<camera>/classification/<model>`), cached by the Hub.
public struct ClassifierReading: Sendable, Equatable {
    public var label: String
    public var score: Double?
    public var at: Date
    public init(label: String, score: Double? = nil, at: Date) {
        self.label = label
        self.score = score
        self.at = at
    }
}

public protocol StateClassifierSource: Sendable {
    func latest(camera: String, model: String) async -> ClassifierReading?
}

public struct NoStateClassifier: StateClassifierSource {
    public init() {}
    public func latest(camera: String, model: String) async -> ClassifierReading? { nil }
}

// MARK: Vision model (tier 1)

public struct JudgeQuestion: @unchecked Sendable {
    public var kind: LookDeviceKind
    public var deviceName: String
    public var expected: LookState
    public var prior: LookState?
    /// Cropped area with some context, before and after the command.
    public var before: CGImage?
    public var after: CGImage
    public var infrared: Bool

    public init(kind: LookDeviceKind, deviceName: String, expected: LookState, prior: LookState?, before: CGImage?,
                after: CGImage, infrared: Bool) {
        self.kind = kind
        self.deviceName = deviceName
        self.expected = expected
        self.prior = prior
        self.before = before
        self.after = after
        self.infrared = infrared
    }
}

public struct JudgeAnswer: Codable, Sendable, Equatable {
    /// The device is clearly visible in the AFTER picture.
    public var visible: Bool
    /// One of the kind's two states, or "unknown".
    public var state: String
    /// "yes" / "no" / "unknown": did it change between the pictures?
    public var changed: String
    public var confidence: Double

    public init(visible: Bool, state: String, changed: String, confidence: Double) {
        self.visible = visible
        self.state = state
        self.changed = changed
        self.confidence = confidence
    }

    public var lookState: LookState? { LookState(rawValue: state) }
}

public enum JudgeError: Error, Equatable, Sendable {
    case unreachable
    case noVision
    case badStatus(Int)
    case invalidOutput
    case timeout
}

public protocol VisualJudge: Sendable {
    /// Cheap probe; false skips the model (the check then ends unknown/unsure).
    func isAvailable() async -> Bool
    func judge(_ question: JudgeQuestion) async throws -> JudgeAnswer
}

/// llama.cpp `llama-server` with a vision model (Qwen3-VL-4B + mmproj),
/// OpenAI-compatible `/v1/chat/completions`, JSON-schema-constrained output.
/// Never brew Ollama: it returns an empty body when given a schema.
public struct LlamaServerJudge: VisualJudge {
    public var baseURL: URL
    public var model: String
    public var timeout: TimeInterval
    private let session: URLSession
    private let probe = ProbeCache()

    public init(baseURL: URL, model: String = "local", timeout: TimeInterval = 8, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config)
        }
    }

    /// `GET /props`: up, and the loaded model takes images. Cached 30 s.
    public func isAvailable() async -> Bool {
        if let cached = await probe.value() { return cached }
        var request = URLRequest(url: baseURL.appendingPathComponent("props"), timeoutInterval: 1.5)
        request.httpMethod = "GET"
        var ok = false
        if let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let modalities = json?["modalities"] as? [String: Any]
            // Older servers have no "modalities": try, and let a 4xx/5xx answer say no.
            ok = (modalities?["vision"] as? Bool) ?? true
        }
        await probe.set(ok)
        return ok
    }

    public func judge(_ question: JudgeQuestion) async throws -> JudgeAnswer {
        guard let body = JudgePrompt.requestBody(question, model: model) else { throw JudgeError.invalidOutput }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            await probe.set(false)
            throw (error as? URLError)?.code == .timedOut ? JudgeError.timeout : JudgeError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw JudgeError.badStatus(status) }
        return try JudgePrompt.decode(data, kind: question.kind)
    }
}

actor ProbeCache {
    private var stored: (Bool, Date)?
    func value() -> Bool? {
        guard let stored, Date().timeIntervalSince(stored.1) < 30 else { return nil }
        return stored.0
    }
    func set(_ v: Bool) { stored = (v, Date()) }
}

/// Prompt, schema, output check — pure, for tests.
public enum JudgePrompt {
    static func noun(_ kind: LookDeviceKind) -> String {
        switch kind {
        case .light: "lamp or light"
        case .tv: "television screen"
        case .shutter: "window shutter (roller blind)"
        case .door: "door"
        }
    }

    static func meaning(_ kind: LookDeviceKind) -> String {
        switch kind {
        case .light: "\"on\" means the light is lit and glowing; \"off\" means it is not lit."
        case .tv: "\"on\" means the screen shows a picture or glows; \"off\" means the screen is black or only reflects the room."
        case .shutter: "\"closed\" means the slats cover the window; \"open\" means you can see through the window."
        case .door: "\"open\" means there is a gap or the door has swung; \"closed\" means it sits flush in its frame."
        }
    }

    public static func schema(kind: LookDeviceKind) -> [String: Any] {
        let (a, b) = kind.states
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["visible", "state", "changed", "confidence"],
            "properties": [
                "visible": ["type": "boolean"],
                "state": ["type": "string", "enum": [a.rawValue, b.rawValue, "unknown"]],
                "changed": ["type": "string", "enum": ["yes", "no", "unknown"]],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
            ],
        ]
    }

    public static func requestBody(_ q: JudgeQuestion, model: String) -> [String: Any]? {
        guard let afterJPEG = JPEG.encode(q.after.scaled(maxSide: 448) ?? q.after, quality: 0.85) else { return nil }
        let (a, b) = q.kind.states
        let system = """
        You check a home camera picture. Answer from the pixels only, never from what is expected. \
        If the \(noun(q.kind)) is not clearly visible (too dark, hidden, blurry, cut off), set visible false and state "unknown". \
        If you are not sure, say "unknown". \(meaning(q.kind))
        """
        var text = "Device: \(noun(q.kind)) (\"\(q.deviceName.prefix(40))\"). States: \(a.rawValue) or \(b.rawValue)."
        if let prior = q.prior { text += " Before the command it was \(prior.rawValue)." }
        text += q.infrared ? " The camera is in night infrared mode (grey picture)." : ""
        var content: [[String: Any]] = []
        if let before = q.before, let beforeJPEG = JPEG.encode(before.scaled(maxSide: 448) ?? before, quality: 0.85) {
            content.append(["type": "text", "text": "Picture 1: BEFORE the command."])
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + beforeJPEG.base64EncodedString()]])
            content.append(["type": "text", "text": "Picture 2: AFTER the command."])
        } else {
            content.append(["type": "text", "text": "Picture: AFTER the command."])
        }
        content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + afterJPEG.base64EncodedString()]])
        content.append(["type": "text", "text": text + " What state is it in AFTER the command?"])
        return [
            "model": model,
            "temperature": 0,
            "max_tokens": 80,
            "cache_prompt": true,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": content],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "device_state", "strict": true, "schema": schema(kind: q.kind)],
            ],
        ]
    }

    public static func decode(_ data: Data, kind: LookDeviceKind) throws -> JudgeAnswer {
        struct Envelope: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let text = envelope.choices.first?.message.content, !text.isEmpty,
              let answer = try? JSONDecoder().decode(JudgeAnswer.self, from: Data(text.utf8)) else {
            throw JudgeError.invalidOutput
        }
        // Re-check against the schema: the grammar should hold, the code still checks.
        let (a, b) = kind.states
        guard [a.rawValue, b.rawValue, "unknown"].contains(answer.state), ["yes", "no", "unknown"].contains(answer.changed),
              (0...1).contains(answer.confidence) else { throw JudgeError.invalidOutput }
        return answer
    }
}
