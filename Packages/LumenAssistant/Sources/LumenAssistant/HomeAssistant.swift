import Foundation

// Home Assistant backend (REST). Written here rather than importing LorisIoT
// `IoTHomeAssistant` (catalogue: source-observed, unqualified): its
// `HAEntityState` drops the attributes this needs (device_class, position,
// temperature, media state), and linking LorisIoT would add a path reference to
// LorisFoundation that collides with the Bridge's remote LorisFoundation package.
// The same safety rules are kept (no bearer over public cleartext, same-origin
// redirects only, byte cap, strict entity ids). See README §Decisions.

public enum HomeAssistantError: Error, Equatable, Sendable {
    case notConfigured
    case unauthorized
    case badStatus(Int)
    case invalidResponse
    case unreachable
    case insecureTransport
}

/// HTTP seam: tests use an in-memory or local mock server.
public protocol HomeAssistantTransport: Sendable {
    func send(method: String, path: String, body: Data?) async throws -> (Data, Int)
}

/// One HA entity with the attributes the assistant reads.
public struct HAEntity: Sendable, Equatable, Decodable {
    public var entityID: String
    public var state: String
    public var friendlyName: String?
    public var deviceClass: String?
    public var brightness: Int?
    public var currentPosition: Int?
    public var temperature: Double?
    public var currentTemperature: Double?
    public var volumeLevel: Double?

    enum CodingKeys: String, CodingKey { case entityID = "entity_id", state, attributes }
    enum Attr: String, CodingKey {
        case friendlyName = "friendly_name", deviceClass = "device_class", brightness
        case currentPosition = "current_position", temperature, currentTemperature = "current_temperature"
        case volumeLevel = "volume_level"
    }

    public init(entityID: String, state: String, friendlyName: String? = nil, deviceClass: String? = nil,
                brightness: Int? = nil, currentPosition: Int? = nil, temperature: Double? = nil) {
        self.entityID = entityID
        self.state = state
        self.friendlyName = friendlyName
        self.deviceClass = deviceClass
        self.brightness = brightness
        self.currentPosition = currentPosition
        self.temperature = temperature
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entityID = try c.decode(String.self, forKey: .entityID)
        state = try c.decode(String.self, forKey: .state)
        let a = try? c.nestedContainer(keyedBy: Attr.self, forKey: .attributes)
        friendlyName = try? a?.decodeIfPresent(String.self, forKey: .friendlyName)
        deviceClass = try? a?.decodeIfPresent(String.self, forKey: .deviceClass)
        brightness = try? a?.decodeIfPresent(Int.self, forKey: .brightness)
        currentPosition = try? a?.decodeIfPresent(Int.self, forKey: .currentPosition)
        temperature = try? a?.decodeIfPresent(Double.self, forKey: .temperature)
        currentTemperature = try? a?.decodeIfPresent(Double.self, forKey: .currentTemperature)
        volumeLevel = try? a?.decodeIfPresent(Double.self, forKey: .volumeLevel)
    }

    public var isOnLike: Bool { ["on", "open", "opening", "playing", "heat", "cool", "auto", "heat_cool", "unlocked"].contains(state) }
}

/// A service call, as previewed (dry run) or sent.
public struct ServiceCall: Sendable, Equatable, Codable {
    public var domain: String
    public var service: String
    public var entityID: String
    public var data: [String: Double]

    public init(domain: String, service: String, entityID: String, data: [String: Double] = [:]) {
        self.domain = domain
        self.service = service
        self.entityID = entityID
        self.data = data
    }

    public var path: String { "api/services/\(domain)/\(service)" }
}

/// What the assistant needs from a home backend. HA today; HomeKit (iPhone
/// side) or LorisIoT later behind the same seam.
public protocol HomeBackend: Sendable {
    func states() async throws -> [HAEntity]
    func state(_ entityID: String) async throws -> HAEntity
    func call(_ call: ServiceCall) async throws
    /// HA area per entity (`POST /api/template`, admin only). Empty when refused.
    func areas(for entityIDs: [String]) async -> [String: String]
}

public actor HomeAssistantClient: HomeBackend {
    private let transport: any HomeAssistantTransport

    public init(transport: any HomeAssistantTransport) { self.transport = transport }

    public func verify() async throws {
        let (_, status) = try await transport.send(method: "GET", path: "api/", body: nil)
        try Self.check(status)
    }

    public func states() async throws -> [HAEntity] {
        let (data, status) = try await transport.send(method: "GET", path: "api/states", body: nil)
        try Self.check(status)
        guard let list = try? JSONDecoder().decode([HAEntity].self, from: data) else { throw HomeAssistantError.invalidResponse }
        return list.filter { Self.isEntityID($0.entityID) }
    }

    public func state(_ entityID: String) async throws -> HAEntity {
        guard Self.isEntityID(entityID) else { throw HomeAssistantError.notConfigured }
        let (data, status) = try await transport.send(method: "GET", path: "api/states/\(entityID)", body: nil)
        try Self.check(status)
        guard let entity = try? JSONDecoder().decode(HAEntity.self, from: data), entity.entityID == entityID else {
            throw HomeAssistantError.invalidResponse
        }
        return entity
    }

    public func call(_ call: ServiceCall) async throws {
        guard Self.isIdentifier(call.domain), Self.isIdentifier(call.service), Self.isEntityID(call.entityID),
              Set(call.data.keys).isDisjoint(with: ["entity_id", "device_id", "area_id", "target"]) else {
            throw HomeAssistantError.notConfigured
        }
        var body: [String: Any] = ["entity_id": call.entityID]
        for (k, v) in call.data { body[k] = v }
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (_, status) = try await transport.send(method: "POST", path: call.path, body: payload)
        try Self.check(status)
    }

    public func areas(for entityIDs: [String]) async -> [String: String] {
        let ids = entityIDs.filter(Self.isEntityID)
        guard !ids.isEmpty else { return [:] }
        let list = ids.map { "'\($0)'" }.joined(separator: ",")
        let template = "{% set ns = namespace(d={}) %}{% for e in [\(list)] %}{% set a = area_name(e) %}"
            + "{% if a %}{% set ns.d = dict(ns.d, **{e: a}) %}{% endif %}{% endfor %}{{ ns.d | tojson }}"
        guard let payload = try? JSONSerialization.data(withJSONObject: ["template": template]),
              let (data, status) = try? await transport.send(method: "POST", path: "api/template", body: payload),
              status == 200, let found = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        let asked = Set(ids)
        return found.filter { asked.contains($0.key) && !$0.value.isEmpty }
    }

    static func check(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw HomeAssistantError.unauthorized
        default: throw HomeAssistantError.badStatus(status)
        }
    }

    static func isIdentifier(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 128 && s.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }

    public static func isEntityID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { isIdentifier(String($0)) }
    }
}

/// URLSession transport: bearer token from a provider (Keychain in the Hub),
/// 5 s timeouts, 4 MB cap, same-origin redirects only, and no token over
/// cleartext HTTP unless the host is on a private network (LAN HA is common).
public final class URLSessionHATransport: NSObject, HomeAssistantTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let baseURL: URL
    private let token: @Sendable () async throws -> String
    private let maxBytes: Int
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public init(baseURL: URL, maxBytes: Int = 4 * 1024 * 1024, token: @escaping @Sendable () async throws -> String) {
        self.baseURL = baseURL
        self.token = token
        self.maxBytes = maxBytes
    }

    public static func normalizedBase(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil, url.user == nil, url.query == nil else { return nil }
        return url
    }

    /// Cleartext is allowed only to loopback, .local, RFC 1918 / CGNAT (Tailscale) hosts.
    public static func permitsBearer(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host == "homeassistant" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    public func send(method: String, path: String, body: Data?) async throws -> (Data, Int) {
        guard !path.hasPrefix("/"), !path.contains("://"), !path.split(separator: "/").contains(".."),
              let url = URL(string: path, relativeTo: baseURL.appendingPathComponent(""))?.absoluteURL,
              url.host == baseURL.host, url.port == baseURL.port else { throw HomeAssistantError.notConfigured }
        guard Self.permitsBearer(baseURL) else { throw HomeAssistantError.insecureTransport }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { throw HomeAssistantError.invalidResponse }
            }
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as HomeAssistantError {
            throw error
        } catch {
            throw HomeAssistantError.unreachable
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // A redirect could carry the bearer elsewhere: never follow one.
        completionHandler(nil)
    }
}

// MARK: - Plans → service calls

public enum ServiceMapper {
    /// Service calls for a plan. `states` gives current values for relative
    /// steps (thermostat ±1 °C). Pure: used for dry-run previews and execution.
    public static func calls(for plan: ActionPlan, states: [String: HAEntity]) -> [ServiceCall] {
        plan.targets.compactMap { device in
            call(plan.action, device: device, value: plan.value, state: states[device.entityID])
        }
    }

    static func call(_ action: DeviceAction, device: Device, value: Double?, state: HAEntity?) -> ServiceCall? {
        let id = device.entityID
        let domain = device.domain
        switch (device.kind, action) {
        case (.light, .raise): return ServiceCall(domain: "light", service: "turn_on", entityID: id, data: ["brightness_step_pct": 25])
        case (.light, .lower): return ServiceCall(domain: "light", service: "turn_on", entityID: id, data: ["brightness_step_pct": -25])
        case (.tv, .raise), (.media, .raise): return ServiceCall(domain: "media_player", service: "volume_up", entityID: id)
        case (.tv, .lower), (.media, .lower): return ServiceCall(domain: "media_player", service: "volume_down", entityID: id)
        case (.fan, .raise): return ServiceCall(domain: "fan", service: "increase_speed", entityID: id)
        case (.fan, .lower): return ServiceCall(domain: "fan", service: "decrease_speed", entityID: id)
        case (_, .turnOn) where device.kind != .shutter && device.kind != .lock && device.kind != .alarm:
            return ServiceCall(domain: domain, service: "turn_on", entityID: id)
        case (_, .turnOff) where device.kind != .shutter && device.kind != .lock && device.kind != .alarm && device.kind != .scene:
            return ServiceCall(domain: domain, service: "turn_off", entityID: id)
        case (.shutter, .open), (.garageDoor, .open): return ServiceCall(domain: "cover", service: "open_cover", entityID: id)
        case (.shutter, .close), (.garageDoor, .close): return ServiceCall(domain: "cover", service: "close_cover", entityID: id)
        case (.shutter, .stop), (.garageDoor, .stop): return ServiceCall(domain: "cover", service: "stop_cover", entityID: id)
        case (.thermostat, .setTemperature):
            guard let value else { return nil }
            return ServiceCall(domain: "climate", service: "set_temperature", entityID: id, data: ["temperature": value])
        case (.thermostat, .raise), (.thermostat, .lower):
            guard let current = state?.temperature else { return nil }
            let target = current + (action == .raise ? 1 : -1)
            return ServiceCall(domain: "climate", service: "set_temperature", entityID: id, data: ["temperature": target])
        case (.lock, .lock): return ServiceCall(domain: "lock", service: "lock", entityID: id)
        case (.lock, .unlock): return ServiceCall(domain: "lock", service: "unlock", entityID: id)
        case (.alarm, .arm): return ServiceCall(domain: "alarm_control_panel", service: "alarm_arm_away", entityID: id)
        case (.alarm, .disarm): return ServiceCall(domain: "alarm_control_panel", service: "alarm_disarm", entityID: id)
        default: return nil
        }
    }

    /// The plan that puts things back as they were (undo), from the states read
    /// just before acting. Nil when there is nothing safe to restore.
    public static func inverse(of plan: ActionPlan, before: [String: HAEntity]) -> [ServiceCall]? {
        var out: [ServiceCall] = []
        for device in plan.targets {
            let id = device.entityID
            let prior = before[id]
            switch (device.kind, plan.action) {
            case (.light, .turnOn), (.light, .turnOff), (.outlet, _), (.fan, .turnOn), (.fan, .turnOff),
                 (.tv, .turnOn), (.tv, .turnOff), (.media, .turnOn), (.media, .turnOff), (.cameraPrivacy, _):
                guard let prior else { return nil }
                let wasOn = prior.state != "off" && prior.state != "standby" && prior.state != "idle"
                out.append(ServiceCall(domain: device.domain, service: wasOn ? "turn_on" : "turn_off", entityID: id))
            case (.light, .raise): out.append(ServiceCall(domain: "light", service: "turn_on", entityID: id, data: ["brightness_step_pct": -25]))
            case (.light, .lower): out.append(ServiceCall(domain: "light", service: "turn_on", entityID: id, data: ["brightness_step_pct": 25]))
            case (.tv, .raise), (.media, .raise): out.append(ServiceCall(domain: "media_player", service: "volume_down", entityID: id))
            case (.tv, .lower), (.media, .lower): out.append(ServiceCall(domain: "media_player", service: "volume_up", entityID: id))
            case (.shutter, .open), (.shutter, .close), (.shutter, .stop):
                if let position = prior?.currentPosition {
                    out.append(ServiceCall(domain: "cover", service: "set_cover_position", entityID: id, data: ["position": Double(position)]))
                } else if let state = prior?.state, ["open", "closed"].contains(state) {
                    out.append(ServiceCall(domain: "cover", service: state == "open" ? "open_cover" : "close_cover", entityID: id))
                } else { return nil }
            case (.thermostat, .setTemperature), (.thermostat, .raise), (.thermostat, .lower):
                guard let t = prior?.temperature else { return nil }
                out.append(ServiceCall(domain: "climate", service: "set_temperature", entityID: id, data: ["temperature": t]))
            case (.thermostat, .turnOn), (.thermostat, .turnOff):
                guard let prior else { return nil }
                out.append(ServiceCall(domain: "climate", service: prior.state == "off" ? "turn_off" : "turn_on", entityID: id))
            default:
                return nil // scenes, T2: no automatic undo
            }
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Registry sync

public enum RegistrySync {
    /// Merges HA entities into the registry. New entities arrive NOT exposed
    /// (the owner picks what the assistant may touch); owner edits (room,
    /// aliases, exposure) survive a resync; removed entities disappear.
    public static func merge(_ entities: [HAEntity], areas: [String: String], into registry: DeviceRegistry) -> DeviceRegistry {
        var out = registry
        var devices: [Device] = []
        for entity in entities {
            let name = entity.friendlyName ?? entity.entityID
            guard let kind = DeviceRegistry.kind(entityID: entity.entityID, deviceClass: entity.deviceClass, name: name),
                  kind != .sensor else { continue }
            if var existing = registry.device(id: entity.entityID) {
                existing.name = name
                existing.kind = kind
                if existing.room == nil { existing.room = areas[entity.entityID] }
                devices.append(existing)
            } else {
                devices.append(Device(entityID: entity.entityID, name: name, kind: kind, room: areas[entity.entityID], exposed: false))
            }
        }
        out.devices = devices.sorted { ($0.room ?? "~", $0.name) < ($1.room ?? "~", $1.name) }
        let roomNames = Set(devices.compactMap(\.room))
        for name in roomNames.sorted() where out.room(named: name) == nil {
            out.rooms.append(Room(name: name))
        }
        return out
    }
}
