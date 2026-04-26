#if os(macOS)
import Foundation
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "Homebridge")

/// Phase 5 v0.2 — HAP **Camera** streaming via a Homebridge sidecar.
///
/// Why Homebridge: Bouke/HAP (used for motion sensors) has zero camera
/// support. Implementing the HomeKit Camera Streaming spec from scratch
/// in Swift (TLV8 cameraRTPStreamManagement, SRTP packet sender, ffmpeg
/// session lifecycle, audio negotiation) is a 2-3 week project. The
/// Node-based `homebridge-camera-ffmpeg` plugin has done this since 2017
/// and is what every commercial Frigate-to-HomeKit product uses
/// (Scrypted Pro, Camera.UI, Cam2HK).
///
/// Strategy: bootstrap a private Homebridge install under the user's
/// Application Support dir, write a `config.json` from Frigate's
/// go2rtc stream list, spawn the `homebridge` binary as a child
/// process, and read the pairing code out of its persist file.
///
/// Sandbox: this manager spawns subprocesses, so the Bridge cannot be
/// distributed via the Mac App Store with this feature on. We ship
/// the camera feature only on the direct-download (notarized DMG)
/// channel; MAS users get motion sensors only.
@MainActor
final class HomebridgeManager {
    // MARK: - Configuration

    /// User-toggle persisted across launches. Independent of the motion-
    /// sensor flag (`lumenbridge.hap.enabled`) so a user can have one,
    /// the other, or both.
    static let camerasEnabledKey = "lumenbridge.homebridge.cameras_enabled"
    /// User-supplied Frigate web URL — homebridge-camera-ffmpeg needs this
    /// to know where to grab the RTSP streams (and snapshots) from. We
    /// don't infer it from the MQTT host because Frigate's web UI and
    /// Mosquitto broker often run on different machines.
    static let frigateWebURLKey = "lumenbridge.homebridge.frigate_web_url"

    // MARK: -

    private let state: BridgeState
    private var process: Process?

    /// Where Homebridge stores its config + persist files. Sandboxed apps
    /// can write here without extra entitlements.
    private var workDir: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Lumen Bridge/homebridge", isDirectory: true)
    }

    init(state: BridgeState) {
        self.state = state
    }

    // MARK: - Lifecycle

    /// Bootstraps Homebridge if needed, writes the per-camera config
    /// from the Frigate API, then launches the process. Idempotent —
    /// calling start() while already running is a no-op.
    func start() async {
        guard process == nil else { return }
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try await ensureHomebridgeInstalled()
            try await writeConfig()
            try launchProcess()
            // The pairing code lands in the persist file once homebridge
            // has booted. Poll a few seconds before surfacing it.
            let s = state
            let weakSelf = WeakBox(self)
            Task { @MainActor in
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let me = weakSelf.value else { return }
                    if let code = me.readPairingCode() {
                        s.homebridgeStatus = .running(setupCode: code)
                        return
                    }
                }
                s.homebridgeStatus = .running(setupCode: "—")
            }
        } catch {
            state.homebridgeStatus = .error(String(describing: error))
            logger.error("Homebridge start failed: \(String(describing: error))")
        }
    }

    func stop() async {
        if let process {
            process.terminate()
            // Don't waitUntilExit() on the main actor — let the kernel
            // clean it up. The next start() guards on `process == nil`.
        }
        process = nil
        state.homebridgeStatus = .stopped
    }

    // MARK: - Bootstrap

    /// Installs homebridge + homebridge-camera-ffmpeg into the app's
    /// support directory using the user's system `npm`. We avoid
    /// touching the global npm prefix so we don't leak our deps into
    /// the user's other Node projects.
    private func ensureHomebridgeInstalled() async throws {
        let nodeModulesURL = workDir.appendingPathComponent("node_modules", isDirectory: true)
        let homebridgeURL = nodeModulesURL.appendingPathComponent("homebridge")
        if FileManager.default.fileExists(atPath: homebridgeURL.path) {
            logger.info("homebridge already present at \(homebridgeURL.path)")
            return
        }
        guard let npm = locateBinary(named: "npm") else {
            throw HomebridgeError.npmNotFound
        }
        // Write a stub package.json so npm knows where to install.
        let packageJSON = workDir.appendingPathComponent("package.json")
        if !FileManager.default.fileExists(atPath: packageJSON.path) {
            let stub = #"{"name":"lumenbridge-homebridge-host","private":true}"#
            try Data(stub.utf8).write(to: packageJSON)
        }
        logger.info("npm install homebridge homebridge-camera-ffmpeg in \(self.workDir.path)")
        let install = Process()
        install.executableURL = npm
        install.arguments = ["install", "--prefix", workDir.path,
                             "--no-audit", "--no-fund",
                             "homebridge", "homebridge-camera-ffmpeg"]
        install.currentDirectoryURL = workDir
        let pipe = Pipe()
        install.standardOutput = pipe
        install.standardError = pipe
        try install.run()
        // Block (off main thread) until npm finishes — installs can take
        // 30-90s on first run. We expose progress via `state` if needed
        // later.
        await Task.detached {
            install.waitUntilExit()
        }.value
        if install.terminationStatus != 0 {
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            let log = String(data: data, encoding: .utf8) ?? "(no output)"
            throw HomebridgeError.installFailed(log)
        }
    }

    /// Writes a Homebridge config that exposes one camera per Frigate
    /// stream, sourcing video from go2rtc's RTSP at port 8554. Each
    /// camera gets a stable serial so HomeKit room assignments survive
    /// across restarts.
    private func writeConfig() async throws {
        guard let webURL = UserDefaults.standard.string(forKey: Self.frigateWebURLKey),
              !webURL.isEmpty else {
            throw HomebridgeError.missingFrigateURL
        }
        let cameras = try await fetchCameras(webURL: webURL)
        let go2rtcHost = URL(string: webURL)?.host ?? "frigate.local"

        let cameraAccessories = cameras.map { name -> [String: Any] in
            return [
                "accessory": "Camera-ffmpeg",
                "name": name.replacingOccurrences(of: "_", with: " ").capitalized,
                "manufacturer": "LorisLabs",
                "model": "Frigate Camera",
                "serialNumber": "lumenbridge-cam-\(name)",
                "firmwareRevision": "0.1.0",
                "videoConfig": [
                    "source": "-rtsp_transport tcp -i rtsp://\(go2rtcHost):8554/\(name)",
                    "stillImageSource": "-i \(webURL)/api/\(name)/latest.jpg",
                    "maxStreams": 2,
                    "maxWidth": 1280,
                    "maxHeight": 720,
                    "maxFPS": 15,
                    "maxBitrate": 2000,
                    "vcodec": "copy",
                    "audio": false,
                ],
            ]
        }

        let config: [String: Any] = [
            "bridge": [
                "name": "Lumen Bridge Cameras",
                // The bridge's own pairing username + pin are auto-generated
                // by homebridge into ~/persist/AccessoryInfo.<MAC>.json on
                // first run.
                "username": Self.deterministicMAC(),
                "port": 51827,
                "pin": "031-45-154", // dummy default; homebridge regenerates
            ],
            "accessories": cameraAccessories,
            "platforms": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: config,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: workDir.appendingPathComponent("config.json"))
        logger.info("Wrote homebridge config with \(cameras.count) cameras")
    }

    private func launchProcess() throws {
        guard let nodeBin = locateBinary(named: "node") else {
            throw HomebridgeError.nodeNotFound
        }
        let homebridgeJS = workDir
            .appendingPathComponent("node_modules/homebridge/bin/homebridge")
        guard FileManager.default.fileExists(atPath: homebridgeJS.path) else {
            throw HomebridgeError.homebridgeBinNotFound(homebridgeJS.path)
        }
        let process = Process()
        process.executableURL = nodeBin
        process.arguments = [
            homebridgeJS.path,
            "-U", workDir.path,           // user storage path
            "--strict-plugin-resolution", // only load plugins from local node_modules
            "-I",                          // insecure mode for ffmpeg snapshot fetch (trusted local network)
        ]
        process.environment = [
            "PATH": (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin",
            "HOME": NSHomeDirectory(),
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        self.process = process
        logger.info("homebridge launched, pid \(process.processIdentifier)")
    }

    // MARK: - Helpers

    /// The pairing code is in `~/persist/AccessoryInfo.<MAC>.json` after
    /// homebridge boots. Read it out for the Settings UI.
    private func readPairingCode() -> String? {
        let persistDir = workDir.appendingPathComponent("persist", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: persistDir, includingPropertiesForKeys: nil) else { return nil }
        let infoFile = entries.first { $0.lastPathComponent.hasPrefix("AccessoryInfo.") }
        guard let infoFile,
              let data = try? Data(contentsOf: infoFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pin = json["pincode"] as? String else { return nil }
        return pin
    }

    /// Looks up `node`/`npm` in the user's PATH plus common Homebrew
    /// locations. We don't bundle Node yet — see commit message for
    /// distribution implications.
    private func locateBinary(named name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Stable MAC-style identifier so the Cameras bridge persists its
    /// HomeKit pairing across restarts. Persisted in UserDefaults.
    private static func deterministicMAC() -> String {
        let key = "lumenbridge.homebridge.bridge_mac"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let bytes = (0..<6).map { _ in String(format: "%02X", Int.random(in: 0...255)) }
        let mac = bytes.joined(separator: ":")
        UserDefaults.standard.set(mac, forKey: key)
        return mac
    }

    private func fetchCameras(webURL: String) async throws -> [String] {
        guard let url = URL(string: "\(webURL)/api/config") else {
            throw HomebridgeError.invalidFrigateURL
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cams = json["cameras"] as? [String: Any] else {
            throw HomebridgeError.frigateConfigUnreadable
        }
        return cams.keys.sorted()
    }

    /// Tiny weak holder so async closures can release us — `weak self`
    /// inside Task closures refused to compile under Swift 6 strict
    /// concurrency without this dance.
    private final class WeakBox<T: AnyObject>: @unchecked Sendable {
        weak var value: T?
        init(_ v: T) { self.value = v }
    }

    enum HomebridgeError: Error {
        case nodeNotFound
        case npmNotFound
        case homebridgeBinNotFound(String)
        case installFailed(String)
        case missingFrigateURL
        case invalidFrigateURL
        case frigateConfigUnreadable
    }
}

/// Lifecycle state of the Homebridge sidecar — separate from `HAPStatus`
/// (motion sensors) so users see whether each piece is alive.
enum HomebridgeStatus: Equatable {
    case stopped
    case running(setupCode: String)
    case error(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var setupCode: String? {
        if case .running(let code) = self { return code }
        return nil
    }
}

#endif
