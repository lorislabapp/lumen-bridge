import Foundation

/// What the camera is asked to check. Kept apart from LumenAssistant's
/// `DeviceKind`: a plug that powers a lamp is a `light` here.
public enum LookDeviceKind: String, Codable, Sendable, CaseIterable {
    case light
    case tv
    case shutter
    /// Doors, gates and garage doors: open / closed.
    case door

    public var states: (positive: LookState, negative: LookState) {
        switch self {
        case .light, .tv: (.on, .off)
        case .shutter, .door: (.open, .closed)
        }
    }

    /// Typical time from command to the end of the change.
    public var defaultTravelSeconds: Double {
        switch self {
        case .light: 2
        case .tv: 6
        case .shutter: 25
        case .door: 15
        }
    }
}

public enum LookState: String, Codable, Sendable, CaseIterable {
    case on, off, open, closed

    /// HA-style state string ("on", "off", "open", "closed", "opening"…).
    public init?(homeAssistant raw: String) {
        switch raw.lowercased() {
        case "on", "playing", "paused", "idle", "buffering": self = .on
        case "off", "standby": self = .off
        case "open": self = .open
        case "closed": self = .closed
        default: return nil
        }
    }

    public var opposite: LookState {
        switch self {
        case .on: .off
        case .off: .on
        case .open: .closed
        case .closed: .open
        }
    }
}

/// A rectangle in 0…1 image coordinates, origin top-left (as drawn in the UI).
public struct LookRect: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Clamped into the unit square, never empty (min 1 % per side).
    public var clamped: LookRect {
        let w = min(max(width, 0.01), 1)
        let h = min(max(height, 0.01), 1)
        return LookRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
    }

    /// Grown by `fraction` of its size on every side (context margin), clamped.
    public func expanded(by fraction: Double) -> LookRect {
        LookRect(x: x - width * fraction, y: y - height * fraction,
                 width: width * (1 + 2 * fraction), height: height * (1 + 2 * fraction)).clamped
    }

    public func offset(dx: Double, dy: Double) -> LookRect {
        LookRect(x: x + dx, y: y + dy, width: width, height: height).clamped
    }

    public var area: Double { width * height }

    public func intersection(_ other: LookRect) -> Double {
        let w = min(x + width, other.x + other.width) - max(x, other.x)
        let h = min(y + height, other.y + other.height) - max(y, other.y)
        return w > 0 && h > 0 ? w * h : 0
    }

    /// Pixel rect for an image of this size (top-left origin, as `CGImage.cropping`).
    public func pixels(width w: Int, height h: Int) -> CGRect {
        let c = clamped
        let px = CGRect(x: (c.x * Double(w)).rounded(.down), y: (c.y * Double(h)).rounded(.down),
                        width: max(1, (c.width * Double(w)).rounded()), height: max(1, (c.height * Double(h)).rounded()))
        return px.intersection(CGRect(x: 0, y: 0, width: w, height: h))
    }
}

/// Appearance of the area in one known state, learned from confirmed checks.
public struct StateSample: Codable, Sendable, Equatable {
    public var features: ROIFeatures
    public var learnedAt: Date
    public init(features: ROIFeatures, learnedAt: Date) {
        self.features = features
        self.learnedAt = learnedAt
    }

    /// Key for the sample dictionary: state × lighting (day colour / night IR).
    public static func key(_ state: LookState, infrared: Bool) -> String { "\(state.rawValue)-\(infrared ? "ir" : "day")" }
}

/// One device the owner pointed at on one camera.
public struct LookTarget: Codable, Sendable, Equatable, Identifiable {
    public var entityID: String
    public var name: String
    public var kind: LookDeviceKind
    public var camera: String
    public var area: LookRect
    /// Seconds from command to end of travel; the check runs then.
    public var travelSeconds: Double
    /// Whole-frame reference (JPEG file name in the store) for the camera-moved check.
    public var referenceFile: String?
    public var referenceTakenAt: Date?
    /// Learned looks, keyed by `StateSample.key`.
    public var samples: [String: StateSample]
    /// Frigate 0.18 state-classification model trained on this area, if any.
    public var frigateModel: String?
    /// Frigate class name → state ("aperto" → open). Empty: class names are the states.
    public var frigateClassMap: [String: LookState]
    public var enabled: Bool

    public var id: String { entityID }

    public init(entityID: String, name: String, kind: LookDeviceKind, camera: String, area: LookRect,
                travelSeconds: Double? = nil, referenceFile: String? = nil, referenceTakenAt: Date? = nil,
                samples: [String: StateSample] = [:], frigateModel: String? = nil,
                frigateClassMap: [String: LookState] = [:], enabled: Bool = true) {
        self.entityID = entityID
        self.name = name
        self.kind = kind
        self.camera = camera
        self.area = area.clamped
        self.travelSeconds = travelSeconds ?? kind.defaultTravelSeconds
        self.referenceFile = referenceFile
        self.referenceTakenAt = referenceTakenAt
        self.samples = samples
        self.frigateModel = frigateModel
        self.frigateClassMap = frigateClassMap
        self.enabled = enabled
    }

    public func sample(_ state: LookState, infrared: Bool) -> StateSample? {
        samples[StateSample.key(state, infrared: infrared)]
    }
}

/// What the assistant asks after acting.
public struct LookRequest: Sendable, Equatable {
    public var entityID: String
    public var expected: LookState
    /// Device-reported state just before the command (HA), when known.
    public var prior: LookState?
    /// When the command was sent.
    public var commandAt: Date
    /// Assistant's own deadline (used when no travel time is set).
    public var deadline: Date
    public var language: String

    public init(entityID: String, expected: LookState, prior: LookState? = nil, commandAt: Date = Date(),
                deadline: Date? = nil, language: String = "fr") {
        self.entityID = entityID
        self.expected = expected
        self.prior = prior
        self.commandAt = commandAt
        self.deadline = deadline ?? commandAt.addingTimeInterval(8)
        self.language = language
    }
}

/// Why the camera could not tell.
public enum UnknownReason: String, Codable, Sendable, CaseIterable {
    /// Night: camera in infrared (grey) mode and the area gave no clear answer.
    case night
    /// Too dark to see, without infrared.
    case tooDark
    /// Camera turned off in Frigate (privacy).
    case privacyMode
    case cameraOffline
    /// Something (a person) stands in front of the area.
    case occluded
    /// The view no longer matches the saved reference: redraw the area.
    case cameraMoved
    /// No frame newer than the command.
    case staleFrame
    /// The pixel test and the model are not sure, or disagree.
    case unsure
    /// No area drawn for this device.
    case noArea
}

public enum LookOutcome: Codable, Sendable, Equatable {
    case confirmed
    /// The camera (or the device itself) shows the opposite state.
    case contradicted(observed: LookState)
    case unknown(UnknownReason)

    public var label: String {
        switch self {
        case .confirmed: "confirmed"
        case .contradicted: "contradicted"
        case .unknown(let r): "unknown:\(r.rawValue)"
        }
    }
}

/// Which signal decided.
public enum LookSource: String, Codable, Sendable {
    case pixels, frigateClassifier, visionModel, device, scene
}

/// Milliseconds per step (the wait for the device's travel is not counted).
public struct LookTiming: Codable, Sendable, Equatable {
    public var fetchMs: Double = 0
    public var sceneMs: Double = 0
    public var pixelsMs: Double = 0
    public var classifierMs: Double = 0
    public var modelMs: Double = 0
    /// Fetch through decision, excluding travel wait.
    public var totalMs: Double = 0
    public init() {}
}

public struct LookResult: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var entityID: String
    public var camera: String
    public var expected: LookState
    public var outcome: LookOutcome
    public var source: LookSource
    /// 0…1, from the signal that decided.
    public var confidence: Double
    /// Short evidence for the log ("area 38→142 brightness").
    public var evidence: String
    /// Device-reported state at check time (HA), if read.
    public var deviceReported: String?
    /// Frigate frame time of the "after" frame (X-Frame-Time), proving it is after the command.
    public var frameTime: Date?
    public var checkedAt: Date
    /// Proof frame (cropped JPEG) file name in the store. Local only, never pushed.
    public var proofFile: String?
    public var retried: Bool
    public var timing: LookTiming
    /// Owner-facing text (push body).
    public var message: String
    /// True for the "Test" button: no command was sent. Optional so older
    /// saved results still decode.
    public var manualTest: Bool?

    public init(id: UUID = UUID(), entityID: String, camera: String, expected: LookState, outcome: LookOutcome,
                source: LookSource, confidence: Double, evidence: String, deviceReported: String? = nil,
                frameTime: Date? = nil, checkedAt: Date = Date(), proofFile: String? = nil, retried: Bool = false,
                timing: LookTiming = LookTiming(), message: String = "") {
        self.id = id
        self.entityID = entityID
        self.camera = camera
        self.expected = expected
        self.outcome = outcome
        self.source = source
        self.confidence = confidence
        self.evidence = evidence
        self.deviceReported = deviceReported
        self.frameTime = frameTime
        self.checkedAt = checkedAt
        self.proofFile = proofFile
        self.retried = retried
        self.timing = timing
        self.message = message
    }
}
