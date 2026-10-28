#if os(macOS)
import Foundation
import CryptoKit
import Darwin
import os

private let logger = Logger(subsystem: "com.lorislabapp.lumenbridge", category: "Homebridge")

/// Serializes asynchronous start/stop jobs across main-actor suspension points.
#if LUMEN_HUB
// Homebridge/Node/ffmpeg launch paths are compiled ONLY into the Developer ID
// "Lumen Hub" build (configuration Hub). The sandboxed Mac App Store build
// gets the inert stub below: HomeKit there is motion sensors and doorbells
// through the in-process HAP server (HAPBridgeManager).
@MainActor
final class HomebridgeLifecycleQueue {
    private var tail: Task<Void, Never>?
    private var revision = 0
    func perform(_ operation: @escaping @MainActor @Sendable () async -> Void) async {
        revision += 1
        let current = revision
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        await task.value
        if revision == current { tail = nil }
    }
}

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


    /// Pinned so an npm release can never silently change what runs.
    /// camera-ffmpeg 4.x (scoped package) is the platform plugin (HKSV
    /// capable); its HTTP automation drives motion and doorbell.
    static let homebridgeVersion = "2.4.0"
    static let cameraPluginVersion = "4.1.0"
    /// The plugin moved to the @homebridge-plugins scope (the unscoped
    /// package stopped at 3.1.4).
    static let cameraPluginPackage = "@homebridge-plugins/homebridge-camera-ffmpeg"
    /// camera-ffmpeg HTTP automation port, bound to localhost only.
    static let automationPort = 51828

    /// Name shown in Apple Home for a Frigate camera ("front_door" → "Front Door").
    /// The HTTP automation addresses cameras by this exact name.
    static func displayName(for camera: String) -> String {
        camera.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // MARK: -

    private let state: BridgeState
    private let lifecycle = HomebridgeLifecycleQueue()
    private var process: Process?
    private var runtimeNode: URL?
    private var snapshotServer: BridgeFrigateSnapshotServer?
    private var cameraCheckTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var restartAttempt = 0
    private var desiredRunning = false
    private var isStarting = false
    private var generation = UUID()

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
        desiredRunning = true
        restartAttempt = 0
        await lifecycle.perform { [weak self] in await self?.startNow() }
    }

    func stop() async {
        desiredRunning = false
        restartTask?.cancel(); restartTask = nil
        await lifecycle.perform { [weak self] in await self?.stopNow() }
    }

    private func startNow() async {
        guard process == nil, !isStarting else { return }
        isStarting = true
        let attempt = UUID()
        generation = attempt
        let previews = BridgeFrigateSnapshotServer()
        defer { if generation == attempt { isStarting = false } }
        do {
            guard let raw = UserDefaults.standard.string(forKey: Self.frigateWebURLKey),
                  let base = Self.normalizedWebURL(raw) else { throw HomebridgeError.missingFrigateURL }
            let credentials = try await BridgeFrigateCredentialStore().load(for: base)
            let session = try BridgeFrigateSession(base: base, credentials: credentials)
            let catalog = try await session.cameraCatalog()
            let cameras = catalog.map(\.id)
            guard Set(catalog.map(\.displayName)).count == cameras.count else { throw BridgeFrigateAccessError.invalidConfiguration }
            guard generation == attempt else { return }
            state.cameraStatuses = catalog
            _ = try await previews.start(cameras: Set(cameras), video: { camera in
                try await session.video(camera: camera)
            }) { camera in
                try await session.snapshot(camera: camera)
            }
            guard generation == attempt else { previews.stop(); return }
            previews.onVideoIssue = { [weak self] camera, issue in
                guard let self, self.generation == attempt,
                      let index = self.state.cameraStatuses.firstIndex(where: { $0.id == camera }) else { return }
                self.state.cameraStatuses[index].phase = issue == .disabled ? .disabled : .unavailable
                self.state.cameraStatuses[index].issue = issue
            }
            snapshotServer = previews
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workDir.path)
            let previousPIN = readPairingCode() ?? existingConfigPIN()
            let pin = try await BridgePairingIdentityStore().loadOrCreate(existingPIN: previousPIN)
            try writeConfig(webURL: base, cameras: cameras, previews: previews, pin: pin)
            try await ensureHomebridgeInstalled()
            guard generation == attempt else { previews.stop(); return }
            try launchProcess()
            checkCameraSources(session: session, attempt: attempt)
            monitorHealth(attempt: attempt)
            let s = state
            let weakSelf = WeakBox(self)
            Task { @MainActor in
                for _ in 0..<10 {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let me = weakSelf.value, me.generation == attempt, me.process?.isRunning == true else { return }
                    if let code = me.readPairingCode() {
                        s.homebridgeStatus = .running(setupCode: code)
                        return
                    }
                }
                guard let me = weakSelf.value, me.generation == attempt, me.process?.isRunning == true else { return }
                s.homebridgeStatus = .running(setupCode: "—")
            }
        } catch {
            previews.stop()
            guard generation == attempt else { return }
            snapshotServer = nil
            let message = (error as? HomebridgeError)?.localizedDescription ?? BridgeFrigateEndpoint.message(for: error)
            state.homebridgeStatus = .error(message)
            logger.error("Homebridge startup failed; see the camera settings for recovery.")
        }
    }

    private func stopNow() async {
        generation = UUID()
        isStarting = false
        cameraCheckTask?.cancel(); cameraCheckTask = nil
        healthTask?.cancel(); healthTask = nil
        snapshotServer?.stop()
        snapshotServer = nil
        for index in state.cameraStatuses.indices where state.cameraStatuses[index].enabled {
            state.cameraStatuses[index].phase = .unchecked
            state.cameraStatuses[index].lastFrameAt = nil
        }
        if let child = process {
            if child.isRunning { child.terminate() }
            let deadline = Date().addingTimeInterval(10)
            while child.isRunning && Date() < deadline {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
            guard !child.isRunning else {
                state.homebridgeStatus = .error(String(localized: "The camera service is still stopping. Wait a few seconds, then try again."))
                return // Keep ownership; never start a second child on the same ports.
            }
            if process === child { process = nil }
        }
        state.homebridgeStatus = .stopped
    }

    // MARK: - Bootstrap

    /// Installs homebridge + homebridge-camera-ffmpeg into the app's
    /// support directory using the user's system `npm`. We avoid
    /// touching the global npm prefix so we don't leak our deps into
    /// the user's other Node projects.
    private func ensureHomebridgeInstalled() async throws {
        runtimeNode = try await compatibleNode()
        let nodeModulesURL = workDir.appendingPathComponent("node_modules", isDirectory: true)
        let homebridgeURL = nodeModulesURL.appendingPathComponent("homebridge")
        let marker = workDir.appendingPathComponent(".lumen-versions")
        let wanted = "\(Self.homebridgeVersion)+\(Self.cameraPluginVersion)"
        if FileManager.default.fileExists(atPath: homebridgeURL.path),
           (try? String(contentsOf: marker, encoding: .utf8)) == wanted,
           (try? installedEntrypoint()) != nil,
           installedPackageVersion(nodeModulesURL.appendingPathComponent(Self.cameraPluginPackage)) == Self.cameraPluginVersion,
           installedPackageVersion(homebridgeURL) == Self.homebridgeVersion {
            logger.info("homebridge \(wanted, privacy: .public) already present")
            return
        }
        guard let node = runtimeNode else { throw HomebridgeError.nodeNotFound }
        let adjacentNPM = node.deletingLastPathComponent().appendingPathComponent("npm")
        guard let npm = FileManager.default.isReadableFile(atPath: adjacentNPM.path) ? adjacentNPM : locateBinary(named: "npm") else {
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
        // npm uses /usr/bin/env node. Invoke it with the chosen compatible
        // runtime explicitly; GUI launches may have no Homebrew on PATH.
        install.executableURL = node
        install.environment = Self.nodeEnvironment(node: node, inherited: ProcessInfo.processInfo.environment)
        install.arguments = [npm.path, "install", "--prefix", workDir.path,
                             "--no-audit", "--no-fund", "--save-exact",
                             "homebridge@\(Self.homebridgeVersion)",
                             "\(Self.cameraPluginPackage)@\(Self.cameraPluginVersion)"]
        install.currentDirectoryURL = workDir
        let pipe = Pipe()
        install.standardOutput = pipe
        install.standardError = pipe
        try install.run()
        // Drain output while npm runs (a full pipe would block it), then
        // wait — installs can take 30-90s on first run.
        let reader = pipe.fileHandleForReading
        let output = await Task.detached { () -> Data in
            let data = (try? reader.readToEnd()) ?? Data()
            install.waitUntilExit()
            return data
        }.value
        if install.terminationStatus != 0 {
            let log = String(data: output.suffix(4000), encoding: .utf8) ?? "(no output)"
            throw HomebridgeError.installFailed(log)
        }
        _ = try installedEntrypoint()
        guard installedPackageVersion(nodeModulesURL.appendingPathComponent(Self.cameraPluginPackage)) == Self.cameraPluginVersion,
              installedPackageVersion(homebridgeURL) == Self.homebridgeVersion else {
            throw HomebridgeError.homebridgeBinNotFound("")
        }
        try Data(wanted.utf8).write(to: marker)
    }

    /// Writes a Homebridge config that exposes one camera per Frigate
    /// stream, sourcing video from go2rtc's RTSP at port 8554. Each
    /// camera gets a stable serial so HomeKit room assignments survive
    /// across restarts.
    private func writeConfig(webURL: String, cameras: [String], previews: BridgeFrigateSnapshotServer, pin: String) throws {
        // Cameras used by a zone alert become video doorbells (chime on
        // HomePods, snapshot in the Home notification), rung on a visit.
        let doorbellCameras = Self.zoneAlertCameras()

        let cameraConfigs = try cameras.map { name -> [String: Any] in
            let stream = try previews.videoURL(camera: name)
            let snapshot = try previews.snapshotURL(camera: name)
            return [
                "name": Self.displayName(for: name),
                "manufacturer": "LorisLabs",
                "model": "Frigate Camera",
                "serialNumber": "lumenbridge-cam-\(name)",
                "firmwareRevision": "0.2.0",
                // Motion sensor linked to the camera; the Hub pulses it from
                // Frigate detections through the localhost HTTP automation.
                "motion": true,
                "motionTimeout": 30,
                "doorbell": doorbellCameras.contains(name),
                "switches": false,
                "videoConfig": [
                    // Authenticated go2rtc fMP4 via the private loopback relay.
                    // Match HomeKit's negotiated H.264 size, frame rate and bitrate.
                    "source": "-i \(stream)",
                    "stillImageSource": "-i \(snapshot)",
                    "maxStreams": 2,
                    "maxWidth": 1280,
                    "maxHeight": 720,
                    "maxFPS": 15,
                    "maxBitrate": 2000,
                    "vcodec": "h264_videotoolbox",
                    "encoderOptions": "-profile:v baseline -level:v 3.1 -realtime 1 -allow_sw 1 -g 30 -bf 0",
                    "packetSize": 1128,
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
                "pin": pin, // New installs are unique; existing pairing identity is preserved.
            ],
            "accessories": [],
            "platforms": [
                [
                    "platform": "Camera-ffmpeg",
                    "name": "Lumen Cameras",
                    // HTTP automation, reachable from this Mac only.
                    "porthttp": Self.automationPort,
                    "localhttp": true,
                    "cameras": cameraConfigs,
                ] as [String: Any],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: config,
                                              options: [.prettyPrinted, .sortedKeys])
        let configURL = workDir.appendingPathComponent("config.json")
        try data.write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        logger.info("Wrote homebridge config with \(cameras.count) cameras")
    }

    private func launchProcess() throws {
        guard let nodeBin = runtimeNode else { throw HomebridgeError.nodeNotFound }
        _ = try installedEntrypoint()
        let homebridgeJS = try Self.writeSourceBoundLauncher(in: workDir)
        let process = Process()
        process.executableURL = nodeBin
        process.arguments = Self.homebridgeArguments(entrypoint: homebridgeJS, workDir: workDir)
        process.currentDirectoryURL = workDir
        var environment = Self.nodeEnvironment(node: nodeBin, inherited: ProcessInfo.processInfo.environment)
        environment["LUMEN_LAUNCH_ID"] = generation.uuidString
        process.environment = environment
        // Log to a file (never an unread pipe: a full pipe freezes the
        // child). Truncated on each launch.
        let logURL = workDir.appendingPathComponent("homebridge.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        let logHandle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        let launchGeneration = generation
        process.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self, self.generation == launchGeneration, self.process === child else { return }
                self.process = nil
                self.snapshotServer?.stop()
                self.snapshotServer = nil
                self.cameraCheckTask?.cancel(); self.healthTask?.cancel()
                self.state.homebridgeStatus = .error(String(localized: "The HomeKit camera service stopped. Turn cameras off and on to retry."))
                self.scheduleRecovery()
            }
        }
        try process.run()
        self.process = process
        logger.info("homebridge launched, pid \(process.processIdentifier)")
    }

    private func existingConfigPIN() -> String? {
        guard let data = try? Data(contentsOf: workDir.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bridge = json["bridge"] as? [String: Any] else { return nil }
        return bridge["pin"] as? String
    }

    func refreshCameraChecks() async {
        guard let base = UserDefaults.standard.string(forKey: Self.frigateWebURLKey) else { return }
        do {
            let credentials = try await BridgeFrigateCredentialStore().load(for: base)
            let session = try BridgeFrigateSession(base: base, credentials: credentials)
            let catalog = try await session.cameraCatalog()
            state.cameraStatuses = catalog
            checkCameraSources(session: session, attempt: generation)
        } catch { state.homebridgeStatus = .error(BridgeFrigateEndpoint.message(for: error)) }
    }

    private func checkCameraSources(session: BridgeFrigateSession, attempt: UUID) {
        cameraCheckTask?.cancel()
        let catalog = state.cameraStatuses
        cameraCheckTask = Task { @MainActor [weak self] in
            await withTaskGroup(of: (String, BridgeCameraIssue?).self) { group in
                var pending = catalog.filter(\.enabled).makeIterator()
                @MainActor func submit(_ camera: BridgeCameraStatus) {
                    self?.updateCamera(camera.id, phase: .checking)
                    group.addTask {
                        do {
                            let stream = try await session.video(camera: camera.id)
                            defer { stream.cancel() }
                            try await stream.validateHeader()
                            return (camera.id, nil)
                        } catch { return (camera.id, BridgeCameraIssue.classify(error)) }
                    }
                }
                for _ in 0..<2 { if let camera = pending.next() { submit(camera) } }
                while let (id, issue) = await group.next() {
                    guard !Task.isCancelled, let self, self.generation == attempt else { group.cancelAll(); return }
                    if let index = self.state.cameraStatuses.firstIndex(where: { $0.id == id }),
                       self.state.cameraStatuses[index].phase != .playing {
                        self.updateCamera(id, phase: issue == nil ? .ready : .unavailable, issue: issue)
                    }
                    if let camera = pending.next() { submit(camera) }
                }
            }
        }
    }

    private func updateCamera(_ id: String, phase: BridgeCameraStatus.Phase, issue: BridgeCameraIssue? = nil) {
        guard let index = state.cameraStatuses.firstIndex(where: { $0.id == id }) else { return }
        state.cameraStatuses[index].phase = phase
        state.cameraStatuses[index].issue = issue
    }

    private struct CameraHealthFile: Decodable {
        struct Entry: Decodable { let camera: String; let active: Bool; let lastFrame: Double? }
        let generation: String
        let entries: [Entry]
    }
    private func monitorHealth(attempt: UUID) {
        healthTask?.cancel()
        healthTask = Task { @MainActor [weak self] in
            let started = Date()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.generation == attempt else { return }
                if Date().timeIntervalSince(started) >= 60 { self.restartAttempt = 0 }
                let url = self.workDir.appendingPathComponent("lumen-camera-health.json")
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536,
                      let data = try? Data(contentsOf: url),
                      let health = try? JSONDecoder().decode(CameraHealthFile.self, from: data),
                      health.generation == attempt.uuidString, health.entries.count <= 256 else { continue }
                for entry in health.entries {
                    guard let index = self.state.cameraStatuses.firstIndex(where: { $0.displayName == entry.camera }),
                          self.state.cameraStatuses[index].enabled else { continue }
                    if let time = entry.lastFrame {
                        let date = Date(timeIntervalSince1970: time / 1000)
                        self.state.cameraStatuses[index].lastFrameAt = date
                        if entry.active {
                            let fresh = Date().timeIntervalSince(date) >= -2 && Date().timeIntervalSince(date) < 15
                            self.updateCamera(self.state.cameraStatuses[index].id, phase: fresh ? .playing : .unavailable,
                                              issue: fresh ? nil : .stalled)
                        } else if self.state.cameraStatuses[index].phase == .playing {
                            self.updateCamera(self.state.cameraStatuses[index].id, phase: .ready)
                        }
                    }
                }
            }
        }
    }

    private func scheduleRecovery() {
        guard desiredRunning, restartAttempt < 3 else { return }
        let delay = [1, 3, 10][restartAttempt]
        restartAttempt += 1
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.desiredRunning else { return }
            await self.lifecycle.perform { [weak self] in await self?.startNow() }
        }
    }

    /// homebridge-camera-ffmpeg 4.1.0 drops PrepareStreamRequest.sourceAddress.
    /// Bind FFmpeg's UDP source to the address actually negotiated by HAP, per session.
    static func writeSourceBoundLauncher(in directory: URL) throws -> URL {
        let adapter = directory.appendingPathComponent("lumen-rtp-source.mjs")
        let launcher = directory.appendingPathComponent("lumen-homebridge.mjs")
        try rtpSourceBinding.write(to: adapter, atomically: true, encoding: .utf8)
        let entry = #"""
        import { readFileSync, writeFileSync, renameSync } from 'node:fs';
        import { installSourceBinding } from './lumen-rtp-source.mjs';
        const manifest = JSON.parse(readFileSync(new URL('./node_modules/@homebridge-plugins/homebridge-camera-ffmpeg/package.json', import.meta.url)));
        if (manifest.version !== '4.1.0') throw new Error('Camera compatibility adapter needs requalification.');
        const { StreamingDelegate } = await import('./node_modules/@homebridge-plugins/homebridge-camera-ffmpeg/dist/streamingDelegate.js');
        const sessions = new Map();
        const frames = new Map();
        const generation = process.env.LUMEN_LAUNCH_ID;
        if (!generation) throw new Error('Missing launcher identity.');
        function writeHealth() {
          const names = new Set([...frames.keys(), ...[...sessions.values()].map(x => x.camera)]);
          const entries = [...names].slice(0, 128).map(camera => ({ camera,
            active: [...sessions.values()].some(x => x.camera === camera), lastFrame: frames.get(camera) ?? null }));
          const temporary = new URL('./lumen-camera-health.json.tmp', import.meta.url);
          writeFileSync(temporary, JSON.stringify({ generation, entries }), { mode: 0o600 });
          renameSync(temporary, new URL('./lumen-camera-health.json', import.meta.url));
        }
        installSourceBinding(StreamingDelegate, {
          onStart: (id, camera) => { sessions.set(id, { camera }); writeHealth(); },
          onProgress: (id, camera, frame) => { if (frame > 0) frames.set(camera, Date.now()); },
          onStop: id => { sessions.delete(id); writeHealth(); }
        });
        setInterval(writeHealth, 1000).unref();
        const parent = process.ppid;
        setInterval(() => { if (process.ppid !== parent) process.kill(process.pid, 'SIGTERM'); }, 1000).unref();
        await import('./node_modules/homebridge/bin/homebridge.js');
        """#
        try entry.write(to: launcher, atomically: true, encoding: .utf8)
        for file in [adapter, launcher] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return launcher
    }

    static let rtpSourceBinding = #"""
    import { isIP } from 'node:net';
    export function installSourceBinding(Delegate, observer = {}) {
      const prototype = Delegate.prototype;
      if (prototype.__lumenSourceBound) return;
      for (const method of ['prepareStream', 'startStream', 'stopStream']) {
        if (typeof prototype[method] !== 'function') throw new Error('Camera streaming API changed.');
      }
      const prepared = new WeakMap();
      const prepare = prototype.prepareStream;
      const start = prototype.startStream;
      const stop = prototype.stopStream;
      prototype.prepareStream = function(request, callback) {
        let source = request.sourceAddress;
        if (typeof source === 'string' && request.addressVersion === 'ipv4' && source.startsWith('::ffff:')) source = source.slice(7);
        if (typeof source !== 'string' || !isIP(source) || /\s/.test(source)) {
          callback(new Error('Invalid negotiated camera source address.'));
          return;
        }
        let sessions = prepared.get(this);
        if (!sessions) { sessions = new Map(); prepared.set(this, sessions); }
        sessions.set(request.sessionID, source);
        if (!this.__lumenShutdownBound && this.api?.on) {
          Object.defineProperty(this, '__lumenShutdownBound', { value: true });
          this.api.on('shutdown', () => {
            for (const id of [...this.ongoingSessions.keys()]) this.stopStream(id);
            prepared.delete(this);
          });
        }
        return prepare.call(this, request, (error, response) => {
          if (error) sessions.delete(request.sessionID);
          callback(error, response);
        });
      };
      prototype.startStream = function(request, callback) {
        const source = prepared.get(this)?.get(request.sessionID);
        if (!source) { callback(new Error('Camera source address was not negotiated.')); return; }
        const previous = this.videoConfig;
        const options = previous.encoderOptions || (previous.vcodec === 'libx264' ? '-preset ultrafast -tune zerolatency' : '');
        this.videoConfig = { ...previous, encoderOptions: `${options} -localaddr ${source}` };
        try {
          const result = start.call(this, request, callback);
          observer.onStart?.(request.sessionID, this.cameraName);
          const main = this.ongoingSessions?.get(request.sessionID)?.mainProcess;
          if (main?.parseProgress) {
            const parse = main.parseProgress;
            const camera = this.cameraName;
            main.parseProgress = function(data) {
              const progress = parse.call(this, data);
              if (progress && Number.isFinite(progress.frame)) observer.onProgress?.(request.sessionID, camera, progress.frame);
              return progress;
            };
          }
          return result;
        } finally { this.videoConfig = previous; }
      };
      prototype.stopStream = function(sessionID) {
        prepared.get(this)?.delete(sessionID);
        observer.onStop?.(sessionID, this.cameraName);
        return stop.call(this, sessionID);
      };
      Object.defineProperty(prototype, '__lumenSourceBound', { value: true });
    }
    """#

    // MARK: - Automation (motion + doorbell)

    /// Cameras used by an enabled zone alert.
    static func zoneAlertCameras() -> Set<String> {
        Set(ZoneAlertStore.load().filter(\.enabled).map(\.configuration.camera))
    }

    var isRunning: Bool { process?.isRunning == true }

    /// Pulses the camera's motion sensor in Apple Home (auto-reset by the plugin).
    func triggerMotion(camera: String) async {
        await callAutomation(path: "motion", camera: camera)
    }

    /// Rings the camera's doorbell: HomePod chime + Home notification with snapshot.
    func triggerDoorbell(camera: String) async {
        await callAutomation(path: "doorbell", camera: camera)
    }

    static func automationURL(path: String, camera: String) -> URL? {
        guard ["motion", "doorbell"].contains(path),
              let name = displayName(for: camera).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        // The plugin's localhttp option binds to localhost (IPv6 on this Mac).
        return URL(string: "http://localhost:\(automationPort)/\(path)?\(name)")
    }

    private func callAutomation(path: String, camera: String) async {
        guard isRunning, let url = Self.automationURL(path: path, camera: camera) else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 { logger.warning("homebridge \(path, privacy: .public) returned \(status)") }
        } catch {
            logger.warning("homebridge \(path, privacy: .public) unreachable")
        }
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

    static func homebridgeArguments(entrypoint: URL, workDir: URL) -> [String] {
        [entrypoint.path, "-U", workDir.path,
         "-P", workDir.appendingPathComponent("node_modules").path,
         "--strict-plugin-resolution", "-I"]
    }

    /// Resolve npm's declared executable rather than hard-coding an obsolete filename.
    static func declaredEntrypoint(packageRoot: URL, manifest: Data) throws -> URL {
        guard let json = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let relative = (json["bin"] as? [String: String])?["homebridge"] ?? json["bin"] as? String,
              !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains(":"), !relative.contains("\\"),
              !relative.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw HomebridgeError.homebridgeBinNotFound("")
        }
        let root = packageRoot.resolvingSymlinksInPath().standardizedFileURL
        let entry = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard entry.path.hasPrefix(root.path + "/") else { throw HomebridgeError.homebridgeBinNotFound("") }
        return entry
    }

    private func installedEntrypoint() throws -> URL {
        let root = workDir.appendingPathComponent("node_modules/homebridge")
        guard let data = try? Data(contentsOf: root.appendingPathComponent("package.json")) else {
            throw HomebridgeError.homebridgeBinNotFound("")
        }
        let entry = try Self.declaredEntrypoint(packageRoot: root, manifest: data)
        guard FileManager.default.isReadableFile(atPath: entry.path) else { throw HomebridgeError.homebridgeBinNotFound("") }
        return entry
    }

    private func installedPackageVersion(_ root: URL) -> String? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    static func supportedNodeVersion(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("v"), let major = Int(text.dropFirst().split(separator: ".").first ?? "") else { return false }
        return major == 22 || major == 24
    }

    static func nodeEnvironment(node: URL, inherited: [String: String]) -> [String: String] {
        // Keep child scripts on the selected Node without forwarding arbitrary app secrets.
        var env = ["PATH": node.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                   "HOME": NSHomeDirectory()]
        for key in ["TMPDIR", "LANG", "LC_ALL"] { if let value = inherited[key] { env[key] = value } }
        return env
    }

    private func compatibleNode() async throws -> URL {
        let paths = [workDir.appendingPathComponent("runtime/" + BridgeNodeRuntime.directoryName + "/bin/node").path,
                     workDir.appendingPathComponent("runtime/node24/bin/node").path,
                     "/opt/homebrew/opt/node@24/bin/node", "/opt/homebrew/opt/node@22/bin/node",
                     "/usr/local/opt/node@24/bin/node", "/usr/local/opt/node@22/bin/node",
                     "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            if let version = try? await BridgeNodeRuntime.probe(URL(fileURLWithPath: path)), Self.supportedNodeVersion(version) {
                return URL(fileURLWithPath: path)
            }
        }
        do {
            return try await BridgeNodeRuntime.install(in: workDir.appendingPathComponent("runtime", isDirectory: true))
        } catch is CancellationError { throw CancellationError() }
        catch { throw HomebridgeError.runtimeInstallFailed }
    }

    /// Looks up `node`/`npm` in the user's PATH plus common Homebrew
    /// locations. A private verified runtime is prepared when none is compatible.
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


    /// Tiny weak holder so async closures can release us — `weak self`
    /// inside Task closures refused to compile under Swift 6 strict
    /// concurrency without this dance.
    ///
    /// **Why `@unchecked Sendable` is safe here:** the wrapped value is
    /// `HomebridgeManager`, which is `@MainActor`-isolated. The only
    /// access path is `weakSelf.value` from inside a `Task { @MainActor in … }`
    /// closure (see `start()` polling loop), so the `weak var` is read
    /// exclusively on the main actor. The box itself is immutable after
    /// init. Audit-tool flag accepted as a known-safe pattern, not a TODO.
    private final class WeakBox<T: AnyObject>: @unchecked Sendable {
        weak var value: T?
        init(_ v: T) { self.value = v }
    }

    enum HomebridgeError: Error, LocalizedError {
        case runtimeInstallFailed
        case nodeNotFound
        case unsupportedNodeVersion
        case npmNotFound
        case homebridgeBinNotFound(String)
        case installFailed(String)
        case missingFrigateURL
        case invalidFrigateURL
        case frigateConfigUnreadable

        var errorDescription: String? {
            switch self {
            case .runtimeInstallFailed: return String(localized: "The camera engine could not be prepared. Check your connection and try again.")
            case .nodeNotFound, .npmNotFound:
                return String(localized: "Install Node.js on this Mac, then enable HomeKit cameras again.")
            case .unsupportedNodeVersion:
                return String(localized: "The camera module requires Node.js 22 or 24. Install Node.js 24 for the Hub, then try again.")
            case .homebridgeBinNotFound:
                return String(localized: "The HomeKit camera module is incomplete. Turn cameras off and on to repair it.")
            case .installFailed:
                return String(localized: "The HomeKit camera module could not be installed. Check the network and try again.")
            case .missingFrigateURL, .invalidFrigateURL:
                return BridgeFrigateAccessError.invalidAddress.localizedDescription
            case .frigateConfigUnreadable:
                return BridgeFrigateAccessError.invalidConfiguration.localizedDescription
            }
        }
    }
}

#else
/// Mac App Store build: no Homebridge, no Node, no child process.
@MainActor
final class HomebridgeManager {
    init(state: BridgeState) {}
    var isRunning: Bool { false }
    func start() async {}
    func stop() async {}
    func refreshCameraChecks() async {}
    func triggerMotion(camera: String) async {}
    func triggerDoorbell(camera: String) async {}
}
#endif

/// Settings shared by both builds (Frigate web address is also used for
/// clips and previews outside the camera module).
extension HomebridgeManager {
    /// User-toggle persisted across launches. Independent of the motion-
    /// sensor flag (`lumenbridge.hap.enabled`) so a user can have one,
    /// the other, or both.
    static let camerasEnabledKey = "lumenbridge.homebridge.cameras_enabled"
    /// User-supplied Frigate web URL — homebridge-camera-ffmpeg needs this
    /// to know where to grab the RTSP streams (and snapshots) from. We
    /// don't infer it from the MQTT host because Frigate's web UI and
    /// Mosquitto broker often run on different machines.
    static let frigateWebURLKey = "lumenbridge.homebridge.frigate_web_url"

    /// Cleans a pasted address: adds http:// when missing, drops a trailing
    /// slash or path. Returns nil when it is not a usable http(s) URL.
    static func normalizedWebURL(_ raw: String) -> String? { BridgeFrigateEndpoint.normalized(raw) }

    enum FrigateCheck: Equatable {
        case ok(version: String, cameras: Int)
        case failed(String)
    }

    /// Checks that a Frigate web address answers (version + camera list),
    /// so the owner sees it works before the camera module uses it.
    static func checkFrigate(webURL: String, credentials: BridgeFrigateCredentials? = nil) async -> FrigateCheck {
        do {
            let session = try BridgeFrigateSession(base: webURL, credentials: credentials)
            let version = try await session.version().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            guard version.count <= 64, version.first?.isNumber == true else { throw BridgeFrigateAccessError.invalidConfiguration }
            let cameras = try await session.cameraNames()
            return .ok(version: version, cameras: cameras.count)
        } catch { return .failed(BridgeFrigateEndpoint.message(for: error)) }
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


#if LUMEN_HUB
/// App-private, pinned runtime bootstrap. Never changes Homebrew or the global Node installation.
enum BridgeNodeRuntime {
    private typealias HomebridgeError = HomebridgeManager.HomebridgeError
    static let version = "24.22.1"
    static let maximumArchiveBytes = 128 * 1024 * 1024
    #if arch(arm64)
    static let architecture = "arm64"
    #else
    static let architecture = "x64"
    #endif
    static var directoryName: String { "node-\(version)-\(architecture)" }
    static func checksum(for architecture: String) -> String? {
        switch architecture {
        case "arm64": "89c682593d76cd44233fa53b1563264e7de9cbb189cad169135c5b4fadfbc0a7"
        case "x64": "d132557e7ee2b85af08b0c8c34338e65c6430f2238d01f727728ef42dc83b035"
        default: nil
        }
    }

    static func install(in root: URL, configuration: URLSessionConfiguration = .ephemeral) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw HomebridgeError.runtimeInstallFailed
        }
        let destination = root.appendingPathComponent(directoryName, isDirectory: true)
        let executable = destination.appendingPathComponent("bin/node")
        if fm.fileExists(atPath: destination.path) {
            guard (try destination.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true,
                  try await probe(executable) == "v" + version else { throw HomebridgeError.runtimeInstallFailed }
            return executable
        }
        // This invocation owns only its newly-created staging directory; never sweep stale folders.
        let staging = root.appendingPathComponent(".node-install-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("node.tar.gz")
        let prefix = "node-v\(version)-darwin-\(architecture)"
        let url = URL(string: "https://nodejs.org/dist/v\(version)/\(prefix).tar.gz")!
        try await download(url, to: archive, configuration: configuration)
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // The exact official archive hash is verified before any archive content is extracted/executed.
        _ = try await run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", archive.path,
            "-C", unpacked.path, "--strip-components=1", prefix + "/bin", prefix + "/lib/node_modules/npm", prefix + "/LICENSE"], timeout: 30)
        let node = unpacked.appendingPathComponent("bin/node")
        guard try await probe(node) == "v" + version,
              fm.isReadableFile(atPath: unpacked.appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js").path) else {
            throw HomebridgeError.runtimeInstallFailed
        }
        // Atomic same-volume move. An existing destination from another instance is never replaced.
        try fm.moveItem(at: unpacked, to: destination)
        return executable
    }

    private static func download(_ url: URL, to archive: URL, configuration: URLSessionConfiguration) async throws {
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: BridgeOriginRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= Int64(maximumArchiveBytes) else { throw HomebridgeError.runtimeInstallFailed }
        guard FileManager.default.createFile(atPath: archive.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw HomebridgeError.runtimeInstallFailed
        }
        let file = try FileHandle(forWritingTo: archive)
        defer { try? file.close() }
        var digest = SHA256()
        var buffer = Data()
        var total = 0
        buffer.reserveCapacity(65536)
        for try await byte in bytes {
            buffer.append(byte)
            total += 1
            guard total <= maximumArchiveBytes else { throw HomebridgeError.runtimeInstallFailed }
            if buffer.count == 65536 {
                try Task.checkCancellation()
                digest.update(data: buffer)
                try file.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        digest.update(data: buffer)
        try file.write(contentsOf: buffer)
        let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == Self.checksum(for: architecture) else { throw HomebridgeError.runtimeInstallFailed }
    }

    static func probe(_ executable: URL) async throws -> String {
        try await run(executable, arguments: ["--version"], timeout: 5)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw HomebridgeError.runtimeInstallFailed }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            // This exact child was created by this invocation and is still owned by its Process handle.
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        guard process.terminationStatus == 0 else { throw HomebridgeError.runtimeInstallFailed }
        return String(data: (try? pipe.fileHandleForReading.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
    }
}

#endif
#endif
