import Foundation
import LumenHearing

/// What kind of thing a Home Assistant entity is, for words and safety.
public enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case light
    case outlet       // switch.* (plugs)
    case fan
    case tv           // media_player with device_class tv, or a name that says TV
    case media        // other media_player (speakers)
    case shutter      // cover: shutter, blind, curtain, awning, window, unclassified
    case scene
    case thermostat   // climate.*
    case cameraPrivacy // camera.* on/off
    case garageDoor   // cover with device_class garage / gate
    case lock
    case alarm
    case sensor       // read-only

    /// Code decides the tier, never the model.
    public var tier: ActionTier {
        switch self {
        case .light, .outlet, .fan, .tv, .media, .shutter, .scene, .sensor: .t0
        case .thermostat, .cameraPrivacy: .t1
        case .garageDoor, .lock, .alarm: .t2
        }
    }

    public var isCover: Bool { self == .shutter || self == .garageDoor }
}

public enum DeviceAction: String, Codable, Sendable, CaseIterable {
    case turnOn = "turn_on"
    case turnOff = "turn_off"
    case open
    case close
    case stop
    /// Brighter / louder / warmer by one step. On a cover: open.
    case raise
    /// Dimmer / quieter / cooler by one step. On a cover: close.
    case lower
    case setTemperature = "set_temperature"
    case lock
    case unlock
    case arm
    case disarm
    /// "Is the kitchen light on?" — read only.
    case query

    public var isReadOnly: Bool { self == .query }
}

/// One controllable entity the owner exposed to the assistant.
public struct Device: Codable, Sendable, Hashable, Identifiable {
    public var entityID: String
    public var name: String
    public var kind: DeviceKind
    public var room: String?
    /// Extra spoken names ("plafonnier", "big lamp").
    public var aliases: [String]
    public var exposed: Bool
    /// Camera that can see it (visual verification, next phase).
    public var verificationCamera: String?

    public var id: String { entityID }
    public var domain: String { String(entityID.split(separator: ".").first ?? "") }

    public init(entityID: String, name: String, kind: DeviceKind, room: String? = nil, aliases: [String] = [],
                exposed: Bool = true, verificationCamera: String? = nil) {
        self.entityID = entityID
        self.name = name
        self.kind = kind
        self.room = room
        self.aliases = aliases
        self.exposed = exposed
        self.verificationCamera = verificationCamera
    }
}

/// A room (Home Assistant area) and the cameras that hear it.
public struct Room: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var aliases: [String]
    public var cameras: [String]
    public var id: String { KeywordMatcher.normalize(name) }

    public init(name: String, aliases: [String] = [], cameras: [String] = []) {
        self.name = name
        self.aliases = aliases
        self.cameras = cameras
    }
}

/// What the assistant is about to do, after parsing and resolution.
public struct ActionPlan: Codable, Sendable, Equatable {
    public var action: DeviceAction
    public var targets: [Device]
    /// Temperature for `setTemperature`.
    public var value: Double?
    public var room: String?

    public init(action: DeviceAction, targets: [Device], value: Double? = nil, room: String? = nil) {
        self.action = action
        self.targets = targets
        self.value = value
        self.room = room
    }

    /// Highest tier of any target (a mixed plan takes the strictest).
    public var tier: ActionTier { targets.map(\.kind.tier).max() ?? .t0 }
    public var effect: ToolEffect { action.isReadOnly ? .readOnly : tier.effect }
}

/// Devices and rooms the assistant may touch. Only `exposed` devices are ever
/// resolved; the registry is synced from Home Assistant entities.
public struct DeviceRegistry: Codable, Sendable, Equatable {
    public var devices: [Device]
    public var rooms: [Room]

    public init(devices: [Device] = [], rooms: [Room] = []) {
        self.devices = devices
        self.rooms = rooms
    }

    public var exposedDevices: [Device] { devices.filter(\.exposed) }

    public func room(named raw: String?) -> Room? {
        guard let raw else { return nil }
        let key = KeywordMatcher.normalize(raw)
        return rooms.first { $0.id == key || $0.aliases.map(KeywordMatcher.normalize).contains(key) }
    }

    /// Room heard by a camera (the default when nobody names a room).
    public func room(forCamera camera: String) -> Room? {
        rooms.first { $0.cameras.contains(camera) }
    }

    public func device(id: String) -> Device? { devices.first { $0.entityID == id } }

    /// Kind of an HA entity from its domain, device class and name.
    public static func kind(entityID: String, deviceClass: String?, name: String) -> DeviceKind? {
        let domain = entityID.split(separator: ".").first.map(String.init) ?? ""
        let words = Set(KeywordMatcher.normalize(name + " " + entityID.replacingOccurrences(of: "_", with: " "))
            .split(separator: " ").map(String.init))
        switch domain {
        case "light": return .light
        case "switch":
            return .outlet
        case "fan": return .fan
        case "media_player":
            if deviceClass == "tv" || !words.isDisjoint(with: ["tv", "tele", "television", "televiseur", "telly"]) { return .tv }
            return .media
        case "cover":
            if deviceClass == "garage" || deviceClass == "gate" || deviceClass == "door"
                || !words.isDisjoint(with: ["garage", "portail", "gate"]) { return .garageDoor }
            return .shutter
        case "scene": return .scene
        case "climate": return .thermostat
        case "camera": return .cameraPrivacy
        case "lock": return .lock
        case "alarm_control_panel": return .alarm
        case "sensor", "binary_sensor": return .sensor
        default: return nil
        }
    }
}

/// JSON persistence for the registry (owner edits rooms, aliases, exposure).
public struct DeviceRegistryStore: Sendable {
    public static let key = "lumenhub.assistant.registry.v1"
    private let suiteName: String?
    public init(suiteName: String? = nil) { self.suiteName = suiteName }
    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> DeviceRegistry {
        guard let data = defaults.data(forKey: Self.key),
              let registry = try? JSONDecoder().decode(DeviceRegistry.self, from: data) else { return DeviceRegistry() }
        return registry
    }

    public func save(_ registry: DeviceRegistry) {
        guard let data = try? JSONEncoder().encode(registry) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
