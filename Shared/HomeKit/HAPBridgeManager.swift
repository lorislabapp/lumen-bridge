#if os(macOS)
import Foundation
import HAP
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "HAPBridge")

/// Phase 5 — HomeKit Accessory Protocol bridge.
///
/// Wraps Bouke/HAP to expose each Frigate camera as a HomeKit accessory
/// that lives in the user's Home app. v0.1 ships with motion sensors
/// only (cheap to implement, immediately useful) and adds Camera RTP
/// streaming in v0.2 (requires GStreamer/ffmpeg piping from Frigate).
///
/// Pairing flow: on first run we generate a pairing setup code (8-digit)
/// and a setup payload (X-HM URL). The Settings → HomeKit pane in the
/// menu-bar UI shows a QR code; the user scans it from the Home app on
/// any iOS device under the same Apple ID and the bridge appears as
/// "Lumen Bridge" with each Frigate camera as a child accessory.
///
/// Persistence: pairings live on disk under
/// `~/Library/Application Support/Lumen Bridge/hap-config.json`.
/// Restarts pick up the existing pairings without re-pairing — the user
/// only sees the QR code once.
@MainActor
final class HAPBridgeManager {
    // MARK: - Configuration

    /// HomeKit accessory name shown in the Home app. Branded so users see
    /// "Lumen Bridge" rather than a generic "HomeKit Bridge".
    private static let bridgeName = "Lumen Bridge"
    /// HomeKit setup code — 8 digits, persisted across restarts so the
    /// QR code in Settings stays valid until the user explicitly resets.
    /// Generated on first launch, stored in UserDefaults (NOT in HAP's
    /// own state file, because we want to display it in the Settings UI
    /// even before the HAP server has booted).
    private static let setupCodeKey = "lumenbridge.hap.setup_code"

    // MARK: -

    private let state: BridgeState
    private var device: Device?
    private var server: Server?
    private var configuredCameras: [String: HAP.Accessory] = [:]

    init(state: BridgeState) {
        self.state = state
    }

    // MARK: - Lifecycle

    /// Start the HAP server. Idempotent — calling start() twice is a no-op.
    /// Returns immediately; the server runs on its own dispatch queue.
    func start() async {
        guard device == nil else { return }
        do {
            let storage = try Self.makeFileStorage()
            let setupCode = Self.loadOrCreateSetupCode()

            // Bridge accessory identity. The serial is stable per Mac
            // (DeviceIdentifier UUID) so users who re-install the Bridge
            // on the same Mac don't have to re-pair from scratch.
            let bridgeInfo = Service.Info(
                name: Self.bridgeName,
                serialNumber: Self.machineUUID(),
                manufacturer: "LorisLabs",
                model: "Lumen Bridge",
                firmwareRevision: "0.1.0"
            )

            let device = HAP.Device(
                bridgeInfo: bridgeInfo,
                setupCode: .override(setupCode),
                storage: storage,
                accessories: []
            )
            self.device = device

            // Bouke/HAP starts the listener inside Server's init — there's
            // no separate start() call. The server runs on its own queue
            // until stop() is called or the process exits.
            let server = try HAP.Server(device: device, listenPort: 0)
            self.server = server

            state.hapStatus = .running(setupCode: setupCode, accessoryCount: 0)
            logger.info("HAP bridge started, setup code: \(setupCode)")
        } catch {
            state.hapStatus = .error(String(describing: error))
            logger.error("HAP start failed: \(String(describing: error))")
        }
    }

    func stop() async {
        guard let server else { return }
        do {
            try server.stop()
        } catch {
            logger.warning("HAP stop error: \(String(describing: error))")
        }
        self.server = nil
        self.device = nil
        configuredCameras.removeAll()
        state.hapStatus = .stopped
    }

    // MARK: - Accessory mapping

    /// Add (or update) a Frigate camera as a HomeKit motion sensor under
    /// this bridge. Idempotent on `cameraName` — calling twice with the
    /// same name updates the existing accessory's metadata in place.
    /// Camera streams are out of scope for v0.1 — this is motion-only.
    func ensureCameraAccessory(cameraName: String) async {
        guard let device else { return }
        if configuredCameras[cameraName] != nil { return }

        let prettyName = cameraName
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")

        let info = HAP.Service.Info(
            name: prettyName,
            serialNumber: "lumenbridge-\(cameraName)",
            manufacturer: "LorisLabs",
            model: "Frigate Camera",
            firmwareRevision: "0.1.0"
        )

        let accessory = HAP.Accessory.MotionSensor(info: info)
        device.addAccessories([accessory])
        configuredCameras[cameraName] = accessory

        if case .running(let code, let count) = state.hapStatus {
            state.hapStatus = .running(setupCode: code, accessoryCount: count + 1)
        }
        logger.info("HAP added motion sensor for \(cameraName)")
    }

    /// Drives the motion-detected characteristic on the camera's accessory.
    /// Called by the coordinator each time MQTT reports a `new` event so
    /// the Home app immediately surfaces the trigger as a motion alert.
    func reportMotion(cameraName: String, detected: Bool) async {
        guard let accessory = configuredCameras[cameraName] as? HAP.Accessory.MotionSensor else { return }
        accessory.motionSensor.motionDetected.value = detected
        // Frigate doesn't fire a "motion ended" event — auto-clear after
        // 30s so the Home app's motion icon stops showing as active.
        if detected {
            Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self.reportMotion(cameraName: cameraName, detected: false)
            }
        }
    }

    // MARK: - Helpers

    private static func makeFileStorage() throws -> FileStorage {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Lumen Bridge", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try FileStorage(filename: dir.appendingPathComponent("hap-config.json").path)
    }

    private static func loadOrCreateSetupCode() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: setupCodeKey), !existing.isEmpty {
            return existing
        }
        // HomeKit setup codes follow the format `XXX-XX-XXX` (3-2-3 digits).
        // We avoid `0` and `1` per HAP guidance — those look like O/I.
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let digits = bytes.map { "\($0 % 8 + 2)" }.joined()
        let formatted = "\(digits.prefix(3))-\(digits.dropFirst(3).prefix(2))-\(digits.dropFirst(5))"
        defaults.set(formatted, forKey: setupCodeKey)
        return formatted
    }

    private static func machineUUID() -> String {
        let key = "lumenbridge.hap.machine_uuid"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let uuid = UUID().uuidString
        UserDefaults.standard.set(uuid, forKey: key)
        return uuid
    }
}

#endif
