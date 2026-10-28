import AppKit
import Foundation
import FrigateKit
import SwiftUI
import XCTest
@testable import Lumen_Bridge

private actor FrigateTransportFixture: BridgeFrigateTransport {
    let acceptsLogin: Bool
    var authenticated = false
    private(set) var loginCalls = 0
    init(acceptsLogin: Bool = true) { self.acceptsLogin = acceptsLogin }
    func login() async -> Bool {
        loginCalls += 1
        try? await Task.sleep(for: .milliseconds(20))
        authenticated = acceptsLogin
        return acceptsLogin
    }
    func expireSession() { authenticated = false }
    func version() async throws -> String {
        guard authenticated else { throw FrigateClientError.unauthorized }
        return "0.16.0"
    }
    func config() async throws -> Data {
        guard authenticated else { throw FrigateClientError.unauthorized }
        return Data(#"{"cameras":{"front":{},"back":{}}}"#.utf8)
    }
    func snapshot(camera: String) async throws -> Data {
        guard authenticated else { throw FrigateClientError.unauthorized }
        return Data([0xff, 0xd8, 0xff, 0xd9])
    }
}

final class BridgeFrigateAccessTests: XCTestCase {
    func testRejectsCredentialsInURLAndKeepsProxyPrefix() {
        XCTAssertNil(BridgeFrigateEndpoint.normalized("https://user:password@server.invalid"))
        XCTAssertEqual(BridgeFrigateEndpoint.normalized(" https://SERVER.invalid/frigate/?q=1#x "), "https://server.invalid/frigate")
        XCTAssertNil(BridgeFrigateEndpoint.normalized("file:///etc/passwd"))
    }
    func testLoginRequiresHTTPS() {
        XCTAssertThrowsError(try BridgeFrigateSession(base: "http://server.invalid:5000", credentials: .init(username: "test", password: "fictional"))) {
            XCTAssertEqual($0 as? BridgeFrigateAccessError, .encryptedLoginRequired)
        }
    }
    func testCameraConfigurationValidation() throws {
        XCTAssertEqual(try BridgeFrigateEndpoint.cameraNames(Data(#"{"cameras":{"front":{},"back":{}}}"#.utf8)), ["back", "front"])
        for data in [Data("<html>login</html>".utf8), Data(#"{"cameras":{"../private":{}}}"#.utf8)] {
            XCTAssertThrowsError(try BridgeFrigateEndpoint.cameraNames(data))
        }
        XCTAssertThrowsError(try BridgeFrigateEndpoint.cameraNames(Data(#"{"cameras":{}}"#.utf8))) {
            XCTAssertEqual($0 as? BridgeFrigateAccessError, .noCameras)
        }
    }
    func testSessionAuthenticatesAndReadsCameraList() async throws {
        let transport = FrigateTransportFixture()
        let session = BridgeFrigateSession(transport: transport, hasCredentials: true)
        let cameras = try await session.cameraNames()
        XCTAssertEqual(cameras, ["back", "front"])
        let calls = await transport.loginCalls
        XCTAssertEqual(calls, 1)
    }
    func testExpiredSessionRenewsBeforeServingSnapshot() async throws {
        let transport = FrigateTransportFixture()
        let session = BridgeFrigateSession(transport: transport, hasCredentials: true)
        _ = try await session.cameraNames()
        await transport.expireSession()
        let image = try await session.snapshot(camera: "front")
        XCTAssertEqual(image, Data([0xff, 0xd8, 0xff, 0xd9]))
        let calls = await transport.loginCalls
        XCTAssertEqual(calls, 2)
    }
    func testConcurrentSnapshotsShareOneLogin() async throws {
        let transport = FrigateTransportFixture()
        let session = BridgeFrigateSession(transport: transport, hasCredentials: true)
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 { group.addTask { try await session.snapshot(camera: "front") } }
            for try await snapshot in group { XCTAssertEqual(snapshot, Data([0xff, 0xd8, 0xff, 0xd9])) }
        }
        let calls = await transport.loginCalls
        XCTAssertEqual(calls, 1)
    }
    func testFailedLoginIsNotRepeatedForEveryPreview() async {
        let transport = FrigateTransportFixture(acceptsLogin: false)
        let session = BridgeFrigateSession(transport: transport, hasCredentials: true)
        for _ in 0..<3 {
            do { _ = try await session.cameraNames(); XCTFail("Invalid login must fail") }
            catch { XCTAssertEqual(error as? BridgeFrigateAccessError, .loginRequired) }
        }
        let calls = await transport.loginCalls
        XCTAssertEqual(calls, 1)
    }
    func testAnonymousSessionDoesNotAttemptLogin() async {
        let transport = FrigateTransportFixture()
        let session = BridgeFrigateSession(transport: transport, hasCredentials: false)
        do { _ = try await session.cameraNames(); XCTFail("Login must be required") }
        catch { XCTAssertEqual(error as? BridgeFrigateAccessError, .loginRequired) }
        let calls = await transport.loginCalls
        XCTAssertEqual(calls, 0)
    }
    @MainActor
    func testSnapshotRoutingRequiresExactCapabilityAndKnownCamera() {
        func request(_ path: String, method: String = "GET") -> Data { Data("\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8) }
        XCTAssertEqual(BridgeFrigateSnapshotServer.camera(for: request("/test/front/snapshot.jpg"), token: "test", cameras: ["front"]), "front")
        for path in ["/wrong/front/snapshot.jpg", "/test/back/snapshot.jpg", "/test/../snapshot.jpg", "/test/front/snapshot.jpg?x=1"] {
            XCTAssertNil(BridgeFrigateSnapshotServer.camera(for: request(path), token: "test", cameras: ["front"]))
        }
        XCTAssertNil(BridgeFrigateSnapshotServer.camera(for: request("/test/front/snapshot.jpg", method: "POST"), token: "test", cameras: ["front"]))
        XCTAssertNil(BridgeFrigateSnapshotServer.camera(for: Data(repeating: 65, count: 4097), token: "test", cameras: ["front"]))
    }
    @MainActor
    func testSnapshotServerServesJPEGAndStops() async throws {
        try XCTSkipUnless(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "Lumen Hub",
                          "The loopback listener is qualified in the non-sandboxed Hub configuration.")
        let server = BridgeFrigateSnapshotServer()
        let port = try await server.start(cameras: ["front"]) { _ in Data([0xff, 0xd8, 0xff, 0xd9]) }
        print("Mission 699CFF76-777B-497E-B296-7B50481324F3 owns test listener 127.0.0.1:\(port) in PID \(ProcessInfo.processInfo.processIdentifier)")
        defer {
            server.stop()
            print("Mission test listener 127.0.0.1:\(port) released")
        }
        let address = try server.snapshotURL(camera: "front")
        let url = try XCTUnwrap(URL(string: address))
        XCTAssertEqual(url.host, "127.0.0.1")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, Data([0xff, 0xd8, 0xff, 0xd9]))
        let badURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(try XCTUnwrap(url.port))/invalid/front/snapshot.jpg"))
        let (_, denied) = try await session.data(from: badURL)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 404)
        server.stop()
        XCTAssertNil(server.port)
        do { _ = try await session.data(from: url); XCTFail("A stopped listener must not serve snapshots") } catch { }
    }
    @MainActor
    func testInternalErrorHasReadableRecoveryText() {
        let message = MainWindow.cameraErrorMessage("frigateConfigUnreadable")
        XCTAssertFalse(message.contains("frigateConfigUnreadable"))
        XCTAssertFalse(message.isEmpty)
    }
    @MainActor
    func testLoginFormRender() throws {
        let content = FrigateWebURLRow(coordinator: nil, initialAddress: "https://frigate.example.invalid")
            .padding(28).frame(width: 760, height: 440, alignment: .topLeading)
            .environment(\.colorScheme, .light)
            .background(Color.white)
        let view = NSHostingView(rootView: content)
        view.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Frigate-authenticated-address-form"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}


#if LUMEN_HUB  // Homebridge/Node launch paths exist only in the Developer ID Hub build.
final class HomebridgeBootstrapTests: XCTestCase {
    @MainActor
    func testResolvesCurrentHomebridgeManifestEntrypoint() throws {
        let root = URL(fileURLWithPath: "/bootstrap-fixture/homebridge")
        let entry = try HomebridgeManager.declaredEntrypoint(packageRoot: root,
            manifest: Data(#"{"bin":{"homebridge":"bin/homebridge.js"}}"#.utf8))
        XCTAssertEqual(entry.path, "/bootstrap-fixture/homebridge/bin/homebridge.js")
        let legacy = try HomebridgeManager.declaredEntrypoint(packageRoot: root,
            manifest: Data(#"{"bin":"bin/homebridge"}"#.utf8))
        XCTAssertEqual(legacy.path, "/bootstrap-fixture/homebridge/bin/homebridge")
    }
    @MainActor
    func testRejectsExecutablePathOutsidePackage() {
        for path in ["../outside.js", "/tmp/outside.js", "bin/../../outside.js", "https://outside.invalid/main.js"] {
            let data = try! JSONSerialization.data(withJSONObject: ["bin": ["homebridge": path]])
            XCTAssertThrowsError(try HomebridgeManager.declaredEntrypoint(packageRoot: URL(fileURLWithPath: "/fixture/package"), manifest: data))
        }
    }
    @MainActor
    func testSelectsOnlySupportedNodeMajors() {
        for version in ["v22.20.0", "v24.22.1\n"] { XCTAssertTrue(HomebridgeManager.supportedNodeVersion(version)) }
        for version in ["v20.19.0", "v26.9.0", "unknown", "24.1.0"] { XCTAssertFalse(HomebridgeManager.supportedNodeVersion(version)) }
    }
    @MainActor
    func testChildEnvironmentUsesSelectedNodeWithoutForwardingSecrets() {
        let env = HomebridgeManager.nodeEnvironment(node: URL(fileURLWithPath: "/isolated/node24/bin/node"),
            inherited: ["PATH": "/unrelated/node26/bin", "PRIVATE_TOKEN": "synthetic", "LANG": "fr_FR.UTF-8"])
        XCTAssertTrue(env["PATH"]?.hasPrefix("/isolated/node24/bin:") == true)
        XCTAssertFalse(env["PATH"]?.contains("node26") == true)
        XCTAssertNil(env["PRIVATE_TOKEN"])
        XCTAssertEqual(env["LANG"], "fr_FR.UTF-8")
    }
}


extension HomebridgeBootstrapTests {
    @MainActor
    func testStrictResolutionIncludesExplicitLocalPluginDirectory() {
        let args = HomebridgeManager.homebridgeArguments(entrypoint: URL(fileURLWithPath: "/fixture/homebridge/bin/homebridge.js"),
                                                        workDir: URL(fileURLWithPath: "/fixture/support"))
        XCTAssertEqual(args.first, "/fixture/homebridge/bin/homebridge.js")
        XCTAssertEqual(args[args.firstIndex(of: "-P")! + 1], "/fixture/support/node_modules")
        XCTAssertEqual(args[args.firstIndex(of: "-U")! + 1], "/fixture/support")
        XCTAssertTrue(args.contains("--strict-plugin-resolution"))
    }
}


@MainActor
private final class LifecycleProbe {
    var active = 0
    var maximum = 0
    var completed = 0
    func slowOperation() async {
        active += 1
        maximum = max(maximum, active)
        try? await Task.sleep(for: .milliseconds(25))
        active -= 1
        completed += 1
    }
}

extension HomebridgeBootstrapTests {
    @MainActor
    func testLifecycleJobsStayExclusiveWhileAwaitingShutdown() async {
        let queue = HomebridgeLifecycleQueue()
        let probe = LifecycleProbe()
        async let first: Void = queue.perform { await probe.slowOperation() }
        async let second: Void = queue.perform { await probe.slowOperation() }
        async let third: Void = queue.perform { await probe.slowOperation() }
        _ = await (first, second, third)
        XCTAssertEqual(probe.maximum, 1)
        XCTAssertEqual(probe.completed, 3)
        XCTAssertEqual(probe.active, 0)
    }
    @MainActor
    func testAutomationUsesSameLocalhostBindingAsPlugin() throws {
        let url = try XCTUnwrap(HomebridgeManager.automationURL(path: "motion", camera: "front_door"))
        XCTAssertEqual(url.host, "localhost")
        XCTAssertEqual(url.port, 51828)
        XCTAssertEqual(url.path, "/motion")
        XCTAssertNil(HomebridgeManager.automationURL(path: "unknown", camera: "front_door"))
    }
}
#endif

private final class BridgeVideoFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let payload = Data([0, 0, 0, 24, 102, 116, 121, 112]) + Data(repeating: 42, count: 65536)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let status = path == "/unauthorized" ? 401 : path == "/redirect" ? 302 : 200
        let type = path == "/html" ? "text/html" : "video/mp4"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Location": "https://other.invalid/"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
    static func stream(path: String = "/video") async throws -> BridgeFrigateVideoStream {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BridgeVideoFixtureProtocol.self]
        return try await BridgeFrigateVideoStream.open(URLRequest(url: URL(string: "https://fixture.invalid" + path)!), configuration: config)
    }
}

extension BridgeFrigateAccessTests {
    func testVideoRejectsUnauthorizedHTMLAndRedirectResponses() async {
        for path in ["/unauthorized", "/html", "/redirect"] {
            do {
                let stream = try await BridgeVideoFixtureProtocol.stream(path: path)
                stream.cancel()
                XCTFail("Invalid upstream response must not become a video stream")
            } catch { }
        }
    }

    @MainActor
    func testVideoProxyStreamsBoundedChunksAndUsesExactCapabilityRoute() async throws {
        try XCTSkipUnless(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "Lumen Hub")
        let server = BridgeFrigateSnapshotServer()
        _ = try await server.start(cameras: ["front"], video: { _ in
            try await BridgeVideoFixtureProtocol.stream()
        }, fetch: { _ in Data([0xff, 0xd8, 0xff, 0xd9]) })
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: server.videoURL(camera: "front")))
        XCTAssertEqual(url.host, "127.0.0.1")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(response.mimeType, "video/mp4")
        XCTAssertEqual(data, BridgeVideoFixtureProtocol.payload)
        let request = Data("GET \(url.path) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        XCTAssertEqual(BridgeFrigateSnapshotServer.camera(for: request, token: server.token, cameras: ["front"], resource: "stream.mp4"), "front")
        XCTAssertNil(BridgeFrigateSnapshotServer.camera(for: request, token: "wrong", cameras: ["front"], resource: "stream.mp4"))
        XCTAssertNil(BridgeFrigateSnapshotServer.camera(for: request, token: server.token, cameras: ["other"], resource: "stream.mp4"))
        server.stop()
        XCTAssertNil(server.port)
    }
}


#if LUMEN_HUB
extension HomebridgeBootstrapTests {
    func testRuntimeMetadataPinsBothSupportedArchitectures() {
        XCTAssertEqual(BridgeNodeRuntime.checksum(for: "arm64"), "89c682593d76cd44233fa53b1563264e7de9cbb189cad169135c5b4fadfbc0a7")
        XCTAssertEqual(BridgeNodeRuntime.checksum(for: "x64"), "d132557e7ee2b85af08b0c8c34338e65c6430f2238d01f727728ef42dc83b035")
        XCTAssertNil(BridgeNodeRuntime.checksum(for: "unsupported"))
    }

    private func runtimeCanaryRoot() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let raw = env["LUMEN_RUNTIME_CANARY_ROOT"] ?? env["TEST_RUNNER_LUMEN_RUNTIME_CANARY_ROOT"] ?? ""
        try XCTSkipUnless(raw.hasPrefix("/Volumes/DeveloperStorage/BuildScratch/Auto/") && raw.contains("throttle-mission-"),
                          "Opt-in network/install canary requires an already-registered exclusive mission folder.")
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    func testRuntimeTamperIsRejectedBeforeExtractionAndStageIsRemoved() async throws {
        let root = try runtimeCanaryRoot().appendingPathComponent("tamper", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BridgeVideoFixtureProtocol.self]
        do {
            _ = try await BridgeNodeRuntime.install(in: root, configuration: config)
            XCTFail("Unverified archive must never be extracted or installed")
        } catch { }
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertTrue(children.isEmpty, "Failed install must remove only its own staging folder")
    }

    func testRuntimeFreshOfficialInstallAndReuse() async throws {
        let root = try runtimeCanaryRoot().appendingPathComponent("official", isDirectory: true)
        let node = try await BridgeNodeRuntime.install(in: root)
        let version = try await BridgeNodeRuntime.probe(node)
        XCTAssertEqual(version, "v" + BridgeNodeRuntime.version)
        let original = try FileManager.default.attributesOfItem(atPath: node.path)[.systemFileNumber] as? NSNumber
        let reused = try await BridgeNodeRuntime.install(in: root)
        XCTAssertEqual(reused, node)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: reused.path)[.systemFileNumber] as? NSNumber, original)
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(children.map(\.lastPathComponent), [BridgeNodeRuntime.directoryName])
    }
}
#endif

extension BridgeFrigateAccessTests {
    func testCameraCatalogPreservesDisabledCamerasWithoutMarkingThemReady() throws {
        let data = Data(#"{"cameras":{"front":{"enabled":true},"paused":{"enabled":false},"legacy":{}}}"#.utf8)
        let cameras = try BridgeFrigateEndpoint.cameraCatalog(data)
        XCTAssertEqual(cameras.map(\.id), ["front", "legacy", "paused"])
        XCTAssertEqual(cameras.last?.phase, .disabled)
        XCTAssertFalse(try XCTUnwrap(cameras.last).enabled)
        XCTAssertTrue(cameras.prefix(2).allSatisfy { $0.phase == .unchecked })
    }
    func testVideoErrorsDistinguishPermissionsSourceAndNetwork() {
        XCTAssertEqual(BridgeCameraIssue.classify(BridgeFrigateAccessError.upstreamVideo(404)), .missingSource)
        XCTAssertEqual(BridgeCameraIssue.classify(BridgeFrigateAccessError.upstreamVideo(403)), .permissions)
        XCTAssertEqual(BridgeCameraIssue.classify(FrigateClientError.unauthorized), .authentication)
        XCTAssertEqual(BridgeCameraIssue.classify(URLError(.timedOut)), .network)
        XCTAssertEqual(BridgeCameraIssue.classify(BridgeFrigateAccessError.videoUnavailable), .invalidMedia)
    }
    func testVideoReadinessRequiresActualMP4Header() async throws {
        let stream = try await BridgeVideoFixtureProtocol.stream()
        defer { stream.cancel() }
        try await stream.validateHeader()
    }
    func testNewPairingPinsAreValidAndNeverTheLegacyDefault() {
        for _ in 0..<50 {
            let pin = BridgePairingIdentityStore.freshPIN()
            XCTAssertTrue(BridgePairingIdentityStore.isValid(pin))
            XCTAssertNotEqual(pin, "031-45-154")
        }
        for invalid in ["111-11-111", "123-45-678", "876-54-321", "bad"] {
            XCTAssertFalse(BridgePairingIdentityStore.isValid(invalid))
        }
        XCTAssertTrue(BridgePairingIdentityStore.isValid("031-45-154"), "Existing paired installs can keep their identity")
    }
    @MainActor
    func testDiagnosticSnapshotAndExportTextNeverContainPairingOrConnectionSecrets() {
        let state = BridgeState()
        state.homebridgeStatus = .running(setupCode: "532-21-908")
        state.frigateHost = "nvr.private.ts.net"
        state.frigatePort = 1883
        state.lastMQTTError = "password: fictionalSecret"
        let snapshot = BridgeStateSnapshot(state: state)
        XCTAssertFalse(snapshot.homebridgeStatusDescription.contains("532-21-908"))
        XCTAssertFalse(snapshot.frigateHost?.contains("private.ts.net") ?? false)
        XCTAssertFalse(snapshot.lastMQTTError?.contains("fictionalSecret") ?? false)
        let input = "532-21-908 X-HM://EXAMPLE123 https://nvr.private.ts.net/capability/secret 192.168.8.4 fe80::abcd%en0 password: fictionalSecret -srtp_out_params YmFyZXNlY3JldA=="
        let redacted = LumenBridgeBugReportContext.redactDiagnosticText(input)
        for secret in ["532-21-908", "EXAMPLE123", "private.ts.net", "192.168.8.4", "fe80::abcd", "fictionalSecret", "YmFyZXNlY3JldA=="] {
            XCTAssertFalse(redacted.contains(secret))
        }
    }
    @MainActor
    func testAvailabilityDoesNotPreventSleepOnBatteryOrWhenDisabled() {
        XCTAssertTrue(HubAvailabilityController.shouldPreventIdleSleep(enabled: true, onACPower: true))
        XCTAssertFalse(HubAvailabilityController.shouldPreventIdleSleep(enabled: true, onACPower: false))
        XCTAssertFalse(HubAvailabilityController.shouldPreventIdleSleep(enabled: false, onACPower: true))
    }
    @MainActor
    func testCloudKitAccountIsNotAdvertisedAsConfirmedNotificationDelivery() {
        let state = BridgeState()
        state.cloudKitStatus = .available
        let role = HubRole.all(from: state).first { $0.id == "push" }
        XCTAssertEqual(role?.tone, .todo)
        XCTAssertNotEqual(role?.status, String(localized: "Active"))
        XCTAssertEqual(HubRole.all(from: state).count, 4)
    }
}
