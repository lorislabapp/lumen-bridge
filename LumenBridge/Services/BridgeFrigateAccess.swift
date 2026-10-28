import CryptoKit
import Foundation
import FrigateKit
import LorisSecurity

struct BridgeFrigateCredentials: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let username: String
    let password: String
    var description: String { "BridgeFrigateCredentials(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

enum BridgeFrigateAccessError: Error, LocalizedError, Equatable {
    case invalidAddress, encryptedLoginRequired, incompleteLogin, loginRequired, accessDenied
    case invalidConfiguration, noCameras, credentialStore, snapshotUnavailable, videoUnavailable
    case cameraDisabled, upstreamVideo(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: String(localized: "Enter a valid Frigate HTTP or HTTPS address without credentials in the URL.")
        case .encryptedLoginRequired: String(localized: "Use an HTTPS address before entering your Frigate login.")
        case .incompleteLogin: String(localized: "Enter both your Frigate username and password.")
        case .loginRequired: String(localized: "Sign in with your Frigate username and password, then test again.")
        case .accessDenied: String(localized: "Frigate refused access. Check this account's permissions or the access proxy.")
        case .invalidConfiguration: String(localized: "This address did not return Frigate's camera configuration. Check the address and sign-in method.")
        case .noCameras: String(localized: "No cameras are available to this Frigate account.")
        case .credentialStore: String(localized: "The login could not be read or saved in this Mac's Keychain. Unlock the Mac and try again.")
        case .snapshotUnavailable: String(localized: "Camera previews could not start. Turn the cameras off and try again.")
        case .cameraDisabled: String(localized: "This camera is disabled in Frigate.")
        case .upstreamVideo: String(localized: "Frigate could not provide this camera stream. Check its live source and permissions.")
        case .videoUnavailable: String(localized: "Frigate could not provide live video. Check that this camera has a working go2rtc live stream.")
        }
    }
}

enum BridgeFrigateEndpoint {
    static func normalized(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "http://" + text }
        guard var c = URLComponents(string: text), let scheme = c.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        c.scheme = scheme
        c.host = host.lowercased()
        c.query = nil
        c.fragment = nil
        while c.path.hasSuffix("/") { c.path.removeLast() }
        return c.url?.absoluteString
    }

    static func cameraNames(_ data: Data) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cameras = root["cameras"] as? [String: Any] else { throw BridgeFrigateAccessError.invalidConfiguration }
        let names = cameras.keys.sorted()
        guard !names.isEmpty else { throw BridgeFrigateAccessError.noCameras }
        // Frigate camera identifiers are used as HTTP and RTSP path components.
        guard names.count <= 128, names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 &&
            $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }
        }) else { throw BridgeFrigateAccessError.invalidConfiguration }
        return names
    }

    static func cameraCatalog(_ data: Data) throws -> [BridgeCameraStatus] {
        let names = try cameraNames(data)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let cameras = root["cameras"] as! [String: Any]
        return names.map { name in
            let config = cameras[name] as? [String: Any] ?? [:]
            return BridgeCameraStatus(id: name, enabled: config["enabled"] as? Bool ?? true)
        }
    }

    static func message(for error: Error) -> String {
        if let e = error as? BridgeFrigateAccessError { return e.localizedDescription }
        if let e = error as? FrigateClientError {
            switch e {
            case .unauthorized: return BridgeFrigateAccessError.loginRequired.localizedDescription
            case .forbidden: return BridgeFrigateAccessError.accessDenied.localizedDescription
            case .proxyAuthPage, .htmlResponse, .unexpectedBody: return BridgeFrigateAccessError.invalidConfiguration.localizedDescription
            default: break
            }
        }
        return String(localized: "Frigate could not be reached. Check the address and your network, then try again.")
    }
}

/// No new password storage implementation: use the existing, pinned LorisSecurity owner.
struct BridgeFrigateCredentialStore: Sendable {
    private let store = SecureStore()
    private func key(for base: String) throws -> KeychainItemKey {
        guard let normalized = BridgeFrigateEndpoint.normalized(base) else { throw BridgeFrigateAccessError.invalidAddress }
        return KeychainItemKey(service: "com.lorislabapp.lumenbridge.frigate-web.v1",
            account: SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined(),
            accessGroup: "TDV6D5L785.com.lorislabapp.lumenbridge")
    }
    func load(for base: String) async throws -> BridgeFrigateCredentials? {
        do {
            guard let secret = try await store.read(key(for: base), expecting: .background) else { return nil }
            return try JSONDecoder().decode(BridgeFrigateCredentials.self, from: secret.dataCopy())
        } catch { throw BridgeFrigateAccessError.credentialStore }
    }
    func save(_ credentials: BridgeFrigateCredentials, for base: String) async throws {
        do { try await store.upsert(Secret(bytes: JSONEncoder().encode(credentials)), for: key(for: base), policy: .background) }
        catch { throw BridgeFrigateAccessError.credentialStore }
    }
    func remove(for base: String) async throws {
        do { try await store.remove(key(for: base)) }
        catch { throw BridgeFrigateAccessError.credentialStore }
    }
}

protocol BridgeFrigateTransport: Sendable {
    func login() async -> Bool
    func version() async throws -> String
    func config() async throws -> Data
    func snapshot(camera: String) async throws -> Data
    func video(camera: String) async throws -> BridgeFrigateVideoStream
}

extension BridgeFrigateTransport {
    func video(camera: String) async throws -> BridgeFrigateVideoStream { throw BridgeFrigateAccessError.videoUnavailable }
}

private struct NativeFrigateTransport: BridgeFrigateTransport {
    let client: FrigateClient
    func login() async -> Bool { await client.login() }
    func version() async throws -> String { try await client.getVersion().version ?? "" }
    func config() async throws -> Data { try await client.getConfigRaw() }
    func snapshot(camera: String) async throws -> Data { try await client.getSnapshot(camera: camera) }
    func video(camera: String) async throws -> BridgeFrigateVideoStream {
        let cameras = try await client.getCameras()
        guard let selected = cameras[camera] else { throw BridgeFrigateAccessError.noCameras }
        guard selected.enabled != false else { throw BridgeFrigateAccessError.cameraDisabled }
        let url = try await client.go2rtcStreamURL(streamName: selected.resolvedStreamName, format: .fmp4)
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = await client.webRTCSignalingHeaders
        request.setValue("video/mp4", forHTTPHeaderField: "Accept")
        return try await BridgeFrigateVideoStream.open(request)
    }
}

/// Reuses FrigateKit's native login and origin-isolated cookie session. Refreshes once on 401.
actor BridgeFrigateSession {
    private let transport: any BridgeFrigateTransport
    private let hasCredentials: Bool
    private var loginTask: Task<Bool, Never>?
    private var generation = 0
    private var nextLoginAttempt = Date.distantPast

    init(base: String, credentials: BridgeFrigateCredentials?) throws {
        guard let clean = BridgeFrigateEndpoint.normalized(base), let url = URL(string: clean) else { throw BridgeFrigateAccessError.invalidAddress }
        if credentials != nil, url.scheme != "https" { throw BridgeFrigateAccessError.encryptedLoginRequired }
        transport = NativeFrigateTransport(client: FrigateClient(baseURL: url,
            credentials: credentials.map { .init(username: $0.username, password: $0.password) },
            networkPolicy: .allNetworks))
        hasCredentials = credentials != nil
    }
    init(transport: any BridgeFrigateTransport, hasCredentials: Bool) {
        self.transport = transport
        self.hasCredentials = hasCredentials
    }
    func version() async throws -> String { try await authenticated { try await self.transport.version() } }
    func cameraCatalog() async throws -> [BridgeCameraStatus] {
        try BridgeFrigateEndpoint.cameraCatalog(await authenticated { try await self.transport.config() })
    }
    func cameraNames() async throws -> [String] {
        let data = try await authenticated { try await self.transport.config() }
        return try BridgeFrigateEndpoint.cameraNames(data)
    }
    func snapshot(camera: String) async throws -> Data {
        try await authenticated { try await self.transport.snapshot(camera: camera) }
    }
    func video(camera: String) async throws -> BridgeFrigateVideoStream {
        try await authenticated { try await self.transport.video(camera: camera) }
    }
    private func authenticated<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if hasCredentials && generation == 0 {
            guard await authenticate() else { throw BridgeFrigateAccessError.loginRequired }
        }
        let observedGeneration = generation
        do { return try await operation() }
        catch FrigateClientError.unauthorized {
            if observedGeneration != generation { return try await operation() }
            guard hasCredentials, await authenticate() else { throw BridgeFrigateAccessError.loginRequired }
            return try await operation()
        }
    }
    private func authenticate() async -> Bool {
        if let loginTask { return await loginTask.value }
        guard Date() >= nextLoginAttempt else { return false }
        let transport = transport
        let task = Task { await transport.login() }
        loginTask = task
        let success = await task.value
        loginTask = nil
        if success { generation += 1 }
        nextLoginAttempt = success ? .distantPast : Date().addingTimeInterval(30)
        return success
    }
}

/// One upstream stream per consumer. Credentials remain in memory, redirects are refused,
/// and downstream backpressure bounds the relay to one 16 KiB application buffer.
final class BridgeFrigateVideoStream: @unchecked Sendable {
    let bytes: URLSession.AsyncBytes
    private let session: URLSession
    private init(bytes: URLSession.AsyncBytes, session: URLSession) {
        self.bytes = bytes
        self.session = session
    }
    func cancel() { session.invalidateAndCancel() }
    deinit { session.invalidateAndCancel() }

    /// Confirms a real MP4 header, not decoded playback; the UI keeps those states separate.
    func validateHeader() async throws {
        try await withTaskCancellationHandler {
            var header = Data()
            for try await byte in bytes {
                header.append(byte)
                if header.count == 12 { break }
            }
            guard header.count == 12, String(data: header[4..<8], encoding: .ascii) == "ftyp" else {
                throw BridgeFrigateAccessError.videoUnavailable
            }
        } onCancel: { self.cancel() }
    }

    static func open(_ request: URLRequest, configuration: URLSessionConfiguration = .ephemeral) async throws -> BridgeFrigateVideoStream {
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 21600
        let session = URLSession(configuration: configuration, delegate: BridgeOriginRedirectGuard(), delegateQueue: nil)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw BridgeFrigateAccessError.videoUnavailable }
            if http.statusCode == 401 { throw FrigateClientError.unauthorized }
            if http.statusCode == 403 { throw BridgeFrigateAccessError.accessDenied }
            guard http.statusCode == 200 else { throw BridgeFrigateAccessError.upstreamVideo(http.statusCode) }
            guard http.mimeType?.lowercased() == "video/mp4" else {
                throw BridgeFrigateAccessError.videoUnavailable
            }
            return BridgeFrigateVideoStream(bytes: bytes, session: session)
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }
}

final class BridgeOriginRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}


struct BridgeCameraStatus: Identifiable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case disabled, unchecked, checking, ready, playing, unavailable }
    let id: String
    let enabled: Bool
    var phase: Phase
    var issue: BridgeCameraIssue?
    var lastFrameAt: Date?
    init(id: String, enabled: Bool) {
        self.id = id; self.enabled = enabled
        self.phase = enabled ? .unchecked : .disabled
    }
    var displayName: String { id.replacingOccurrences(of: "_", with: " ").capitalized }
    var detail: String {
        switch phase {
        case .disabled: return String(localized: "Disabled in Frigate")
        case .unchecked: return String(localized: "Video not checked")
        case .checking: return String(localized: "Checking the video source…")
        case .ready: return String(localized: "Video source responding · open in Home to verify playback")
        case .playing: return String(localized: "Video frames are being sent to Home")
        case .unavailable: return (issue ?? .unknown).message
        }
    }
}

enum BridgeCameraIssue: String, Codable, Sendable {
    case disabled, authentication, permissions, missingSource, network, invalidMedia, stalled, unknown
    var message: String {
        switch self {
        case .disabled: String(localized: "Disabled in Frigate")
        case .authentication: String(localized: "Sign in to Frigate again")
        case .permissions: String(localized: "This account cannot access this camera")
        case .missingSource: String(localized: "Live source missing · check this camera in Frigate")
        case .network: String(localized: "Video connection failed · check the network and Frigate")
        case .invalidMedia: String(localized: "The live source did not return playable video")
        case .stalled: String(localized: "Video stopped arriving · reopen the camera in Home")
        case .unknown: String(localized: "Video unavailable · test this camera again")
        }
    }
    static func classify(_ error: Error) -> Self {
        if let error = error as? BridgeFrigateAccessError {
            switch error {
            case .cameraDisabled: return .disabled
            case .loginRequired: return .authentication
            case .accessDenied: return .permissions
            case .upstreamVideo(404): return .missingSource
            case .upstreamVideo(401): return .authentication
            case .upstreamVideo(403): return .permissions
            case .upstreamVideo(500...599): return .network
            case .videoUnavailable: return .invalidMedia
            default: return .unknown
            }
        }
        if let error = error as? FrigateClientError {
            switch error {
            case .unauthorized: return .authentication
            case .forbidden: return .permissions
            case .httpError(404): return .missingSource
            default: return .network
            }
        }
        return error is URLError ? .network : .unknown
    }
}

/// Existing installs keep their PIN; only first-time installs receive a new unique identity secret.
struct BridgePairingIdentityStore {
    private let store = SecureStore()
    private let key = KeychainItemKey(service: "com.lorislabapp.lumenbridge.homebridge-identity.v1",
        account: "setup-pin", accessGroup: "TDV6D5L785.com.lorislabapp.lumenbridge")
    static func isValid(_ value: String) -> Bool {
        guard value.range(of: "^[0-9]{3}-[0-9]{2}-[0-9]{3}$", options: .regularExpression) != nil else { return false }
        let digits = value.replacingOccurrences(of: "-", with: "")
        return Set(digits).count > 1 && digits != "12345678" && digits != "87654321"
    }
    static func freshPIN() -> String {
        while true {
            let digits = String(format: "%08d", Int.random(in: 0...99_999_999))
            let code = String(digits.prefix(3)) + "-" + String(digits.dropFirst(3).prefix(2)) + "-" + String(digits.suffix(3))
            if isValid(code), code != "031-45-154" { return code }
        }
    }
    func loadOrCreate(existingPIN: String?) async throws -> String {
        if let secret = try await store.read(key, expecting: .background),
           let code = String(data: secret.dataCopy(), encoding: .utf8), Self.isValid(code) { return code }
        let code = existingPIN.flatMap { Self.isValid($0) ? $0 : nil } ?? Self.freshPIN()
        try await store.upsert(Secret(bytes: Data(code.utf8)), for: key, policy: .background)
        return code
    }
}
