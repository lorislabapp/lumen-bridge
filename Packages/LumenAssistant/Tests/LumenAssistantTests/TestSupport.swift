import Foundation
import LumenHearing
import Network
@testable import LumenAssistant

enum Fixture {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    /// A French/English home: rooms with the cameras that hear them.
    static let registry = DeviceRegistry(
        devices: [
            Device(entityID: "light.salon_plafond", name: "Plafonnier salon", kind: .light, room: "Salon"),
            Device(entityID: "light.salon_lampe", name: "Lampe de lecture", kind: .light, room: "Salon"),
            Device(entityID: "light.cuisine", name: "Lumière cuisine", kind: .light, room: "Cuisine"),
            Device(entityID: "light.chambre", name: "Lampe chambre", kind: .light, room: "Chambre"),
            Device(entityID: "light.bureau", name: "Lampe bureau", kind: .light, room: "Bureau", exposed: false),
            Device(entityID: "media_player.tv_salon", name: "TV Salon", kind: .tv, room: "Salon"),
            Device(entityID: "media_player.sonos_cuisine", name: "Sonos cuisine", kind: .media, room: "Cuisine"),
            Device(entityID: "cover.volets_salon", name: "Volets salon", kind: .shutter, room: "Salon"),
            Device(entityID: "cover.volet_chambre", name: "Volet chambre", kind: .shutter, room: "Chambre"),
            Device(entityID: "climate.salon", name: "Thermostat salon", kind: .thermostat, room: "Salon"),
            Device(entityID: "lock.porte_entree", name: "Porte d'entrée", kind: .lock, room: "Entrée"),
            Device(entityID: "cover.garage", name: "Porte de garage", kind: .garageDoor, room: "Garage"),
            Device(entityID: "alarm_control_panel.maison", name: "Alarme maison", kind: .alarm),
            Device(entityID: "switch.sapin", name: "Sapin", kind: .outlet, room: "Salon"),
            Device(entityID: "fan.chambre", name: "Ventilateur chambre", kind: .fan, room: "Chambre"),
            Device(entityID: "camera.salon", name: "Caméra salon", kind: .cameraPrivacy, room: "Salon"),
        ],
        rooms: [
            Room(name: "Salon", aliases: ["séjour", "living room", "lounge"], cameras: ["salon"]),
            Room(name: "Cuisine", aliases: ["kitchen"], cameras: ["cuisine"]),
            Room(name: "Chambre", aliases: ["bedroom"], cameras: ["chambre"]),
            Room(name: "Entrée", aliases: ["hall", "entrance"], cameras: ["entree"]),
            Room(name: "Garage", aliases: []),
        ])

    /// Hearing settings with consent on the indoor cameras.
    static func hearing(staff: Bool = false) -> HearingSettings {
        var h = HearingSettings()
        h.enabled = true
        for camera in ["salon", "cuisine", "chambre", "entree"] {
            try! h.grantConsent(camera: camera, placement: .indoor, at: Date(timeIntervalSince1970: 0))
        }
        h.setPlacement(.outdoor, camera: "porte")
        h.staffPresent = staff
        return h
    }

    static func settings(mode: AssistantMode = .wakePhrase, dryRun: Bool = false) -> AssistantSettings {
        var s = AssistantSettings()
        s.enabled = true
        s.mode = mode
        s.dryRun = dryRun
        s.cameras = ["salon", "cuisine", "chambre", "entree", "porte"]
        s.llmEnabled = false
        return s
    }
}

/// In-memory Home Assistant: records calls and applies them to states.
actor MockHomeBackend: HomeBackend {
    var entities: [String: HAEntity]
    private(set) var calls: [ServiceCall] = []
    var failNext = false

    init(_ entities: [HAEntity] = MockHomeBackend.defaultStates) {
        self.entities = Dictionary(uniqueKeysWithValues: entities.map { ($0.entityID, $0) })
    }

    static let defaultStates: [HAEntity] = [
        HAEntity(entityID: "light.salon_plafond", state: "off", friendlyName: "Plafonnier salon"),
        HAEntity(entityID: "light.salon_lampe", state: "off", friendlyName: "Lampe de lecture"),
        HAEntity(entityID: "light.cuisine", state: "on", friendlyName: "Lumière cuisine"),
        HAEntity(entityID: "light.chambre", state: "off", friendlyName: "Lampe chambre"),
        HAEntity(entityID: "media_player.tv_salon", state: "off", friendlyName: "TV Salon", deviceClass: "tv"),
        HAEntity(entityID: "media_player.sonos_cuisine", state: "idle", friendlyName: "Sonos cuisine"),
        HAEntity(entityID: "cover.volets_salon", state: "open", friendlyName: "Volets salon", deviceClass: "shutter", currentPosition: 100),
        HAEntity(entityID: "cover.volet_chambre", state: "closed", friendlyName: "Volet chambre", deviceClass: "shutter", currentPosition: 0),
        HAEntity(entityID: "climate.salon", state: "heat", friendlyName: "Thermostat salon", temperature: 20),
        HAEntity(entityID: "lock.porte_entree", state: "locked", friendlyName: "Porte d'entrée"),
        HAEntity(entityID: "cover.garage", state: "closed", friendlyName: "Porte de garage", deviceClass: "garage"),
    ]

    func states() async throws -> [HAEntity] { Array(entities.values) }
    func state(_ entityID: String) async throws -> HAEntity {
        guard let e = entities[entityID] else { throw HomeAssistantError.badStatus(404) }
        return e
    }
    func call(_ call: ServiceCall) async throws {
        if failNext { failNext = false; throw HomeAssistantError.unreachable }
        calls.append(call)
        guard var e = entities[call.entityID] else { return }
        switch call.service {
        case "turn_on": e.state = "on"
        case "turn_off": e.state = "off"
        case "open_cover": e.state = "open"; e.currentPosition = 100
        case "close_cover": e.state = "closed"; e.currentPosition = 0
        case "set_cover_position":
            let p = Int(call.data["position"] ?? 0)
            e.currentPosition = p
            e.state = p > 0 ? "open" : "closed"
        case "set_temperature": e.temperature = call.data["temperature"]
        case "lock": e.state = "locked"
        case "unlock": e.state = "unlocked"
        default: break
        }
        entities[call.entityID] = e
    }
    func areas(for entityIDs: [String]) async -> [String: String] { [:] }
    func setState(_ id: String, _ state: String) { entities[id]?.state = state }
    func setFailNext() { failNext = true }
}

actor RecordingNotifier: AssistantNotifier {
    private(set) var notices: [AssistantNotice] = []
    func notify(_ notice: AssistantNotice) async { notices.append(notice) }
}

struct FixedSpeaker: UtteranceSpeakerIdentifier {
    var standing: SpeakerStanding
    func identify(_ audio: PCMAudio, camera: String) async -> SpeakerStanding { standing }
}

/// A tiny HTTP/1.1 server on 127.0.0.1 that speaks a subset of the HA REST
/// API (states, services, template). Records requests and auth headers.
final class MockHAServer: @unchecked Sendable {
    struct Request: Sendable { var method: String; var path: String; var authorization: String?; var body: Data }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "mock-ha")
    private let lock = NSLock()
    private var _requests: [Request] = []
    private var states: [String: [String: Any]]
    let token: String
    var requests: [Request] { lock.withLock { _requests } }
    private(set) var port: UInt16 = 0

    init(token: String) throws {
        self.token = token
        states = [
            "light.salon_plafond": ["entity_id": "light.salon_plafond", "state": "off",
                                    "attributes": ["friendly_name": "Plafonnier salon"]],
            "cover.volets_salon": ["entity_id": "cover.volets_salon", "state": "open",
                                   "attributes": ["friendly_name": "Volets salon", "device_class": "shutter", "current_position": 100]],
            "media_player.tv_salon": ["entity_id": "media_player.tv_salon", "state": "off",
                                      "attributes": ["friendly_name": "TV Salon", "device_class": "tv"]],
            "lock.porte_entree": ["entity_id": "lock.porte_entree", "state": "locked",
                                  "attributes": ["friendly_name": "Porte d'entrée"]],
            "sensor.temp": ["entity_id": "sensor.temp", "state": "21", "attributes": ["friendly_name": "Temp"]],
        ]
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
        var buffer = Data()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
                guard let self else { return }
                if let data { buffer.append(data) }
                if let request = Self.parse(buffer) {
                    self.respond(request, on: connection)
                } else if !done {
                    readMore()
                } else {
                    connection.cancel()
                }
            }
        }
        readMore()
    }

    static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), authorization: headers["authorization"],
                       body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }

    private func respond(_ request: Request, on connection: NWConnection) {
        lock.withLock { _requests.append(request) }
        var status = 200
        var body = Data("{}".utf8)
        if request.authorization != "Bearer \(token)" {
            status = 401
        } else if request.method == "GET", request.path == "/api/" {
            body = Data(#"{"message":"API running."}"#.utf8)
        } else if request.method == "GET", request.path == "/api/states" {
            body = try! JSONSerialization.data(withJSONObject: lock.withLock { Array(states.values) })
        } else if request.method == "GET", request.path.hasPrefix("/api/states/") {
            let id = String(request.path.dropFirst("/api/states/".count))
            if let s = lock.withLock({ states[id] }) { body = try! JSONSerialization.data(withJSONObject: s) } else { status = 404 }
        } else if request.method == "POST", request.path.hasPrefix("/api/services/") {
            let parts = request.path.split(separator: "/")
            let service = String(parts.last ?? "")
            if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
               let id = json["entity_id"] as? String {
                lock.withLock {
                    switch service {
                    case "turn_on": states[id]?["state"] = "on"
                    case "turn_off": states[id]?["state"] = "off"
                    case "close_cover": states[id]?["state"] = "closed"
                    case "open_cover": states[id]?["state"] = "open"
                    default: break
                    }
                }
            }
            body = Data("[]".utf8)
        } else if request.method == "POST", request.path == "/api/template" {
            body = Data(#"{"light.salon_plafond":"Salon","cover.volets_salon":"Salon","media_player.tv_salon":"Salon","lock.porte_entree":"Entrée"}"#.utf8)
        } else {
            status = 404
        }
        let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : "Not Found")
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    func state(_ id: String) -> String? { lock.withLock { states[id]?["state"] as? String } }
}

func tempURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lumen-assistant-tests-\(UUID().uuidString)")
        .appendingPathComponent(name)
}
