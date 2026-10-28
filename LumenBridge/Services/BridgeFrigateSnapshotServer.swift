import Foundation
import Network

/// Serves only configured JPEG snapshots on loopback. Frigate credentials stay in FrigateKit,
/// never in Homebridge config, ffmpeg arguments, or image files.
@MainActor
final class BridgeFrigateSnapshotServer {
    var onVideoIssue: (@MainActor @Sendable (String, BridgeCameraIssue) -> Void)?
    private var listener: NWListener?
    private var startup: CheckedContinuation<UInt16, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var cameras: Set<String> = []
    private var streamTasks: [UUID: Task<Void, Never>] = [:]
    private var fetchVideo: (@Sendable (String) async throws -> BridgeFrigateVideoStream)?
    private var fetch: (@Sendable (String) async throws -> Data)?
    private(set) var token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private(set) var port: UInt16?
    private let queue = DispatchQueue(label: "com.lorislabapp.lumenbridge.snapshots")

    func start(cameras: Set<String>, video: (@Sendable (String) async throws -> BridgeFrigateVideoStream)? = nil, fetch: @escaping @Sendable (String) async throws -> Data) async throws -> UInt16 {
        stop()
        self.cameras = cameras
        self.fetch = fetch
        self.fetchVideo = video
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        guard let port = listener?.port?.rawValue else { self.finishStartup(.failure(BridgeFrigateAccessError.snapshotUnavailable)); return }
                        self.port = port
                        self.finishStartup(.success(port))
                    case .failed, .cancelled:
                        self.finishStartup(.failure(BridgeFrigateAccessError.snapshotUnavailable))
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        finishStartup(.failure(BridgeFrigateAccessError.snapshotUnavailable))
        for task in deadlines.values { task.cancel() }
        for task in streamTasks.values { task.cancel() }
        streamTasks.removeAll()
        fetchVideo = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        deadlines.removeAll()
        fetch = nil
        cameras.removeAll()
    }

    func snapshotURL(camera: String) throws -> String {
        guard let port, cameras.contains(camera) else { throw BridgeFrigateAccessError.snapshotUnavailable }
        return "http://127.0.0.1:\(port)/\(token)/\(camera)/snapshot.jpg"
    }

    func videoURL(camera: String) throws -> String {
        guard let port, cameras.contains(camera), fetchVideo != nil else { throw BridgeFrigateAccessError.videoUnavailable }
        return "http://127.0.0.1:\(port)/\(token)/\(camera)/stream.mp4"
    }

    /// Bounded exact routing, also exercised without any network by unit tests.
    static func camera(for request: Data, token: String, cameras: Set<String>, resource: String = "snapshot.jpg") -> String? {
        guard request.count <= 4096, let raw = String(data: request, encoding: .utf8),
              raw.contains("\r\n\r\n"), let first = raw.components(separatedBy: "\r\n").first else { return nil }
        let words = first.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, words[0] == "GET", words[2] == "HTTP/1.1" || words[2] == "HTTP/1.0" else { return nil }
        let parts = words[1].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty, parts[1] == token, parts[3] == Substring(resource),
              cameras.contains(String(parts[2])) else { return nil }
        return String(parts[2])
    }

    private func finishStartup(_ result: Result<UInt16, Error>) {
        guard let continuation = startup else { return }
        startup = nil
        continuation.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 8, listener != nil else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        deadlines[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.finish(id)
        }
        connection.start(queue: queue)
        receive(id, buffer: Data())
    }

    private func receive(_ id: UUID, buffer: Data) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096 - buffer.count) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var bytes = buffer
                if let data { bytes.append(data) }
                if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                    if let camera = Self.camera(for: bytes, token: self.token, cameras: self.cameras, resource: "stream.mp4"),
                       let video = self.fetchVideo {
                        self.relayVideo(id, camera: camera, fetch: video)
                        return
                    }
                    guard let camera = Self.camera(for: bytes, token: self.token, cameras: self.cameras), let fetch = self.fetch else {
                        self.reply(id, status: 404, body: Data()); return
                    }
                    do {
                        let image = try await fetch(camera)
                        guard image.count <= 8 * 1024 * 1024, image.starts(with: [0xff, 0xd8]) else {
                            self.reply(id, status: 502, body: Data()); return
                        }
                        self.reply(id, status: 200, body: image)
                    } catch { self.reply(id, status: 503, body: Data()) }
                } else if bytes.count >= 4096 || complete || error != nil {
                    self.reply(id, status: 400, body: Data())
                } else { self.receive(id, buffer: bytes) }
            }
        }
    }

    private func relayVideo(_ id: UUID, camera: String,
                            fetch: @escaping @Sendable (String) async throws -> BridgeFrigateVideoStream) {
        guard let connection = connections[id] else { return }
        deadlines.removeValue(forKey: id)?.cancel()
        // Monitor client close while the upstream body is read. No request body is accepted.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
            Task { @MainActor in self?.finish(id) }
        }
        streamTasks[id] = Task.detached { [weak self] in
            do {
                let stream = try await fetch(camera)
                defer { stream.cancel() }
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    let header = Data("HTTP/1.0 200 OK\r\nContent-Type: video/mp4\r\nCache-Control: no-store\r\nAccept-Ranges: none\r\nConnection: close\r\n\r\n".utf8)
                    try await Self.send(header, to: connection)
                    var buffer = Data()
                    buffer.reserveCapacity(16384)
                    for try await byte in stream.bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if buffer.count == 16384 {
                            try await Self.send(buffer, to: connection)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { try await Self.send(buffer, to: connection) }
                } onCancel: { stream.cancel() }
                await self?.finish(id)
            } catch {
                if !Task.isCancelled { await self?.reportVideoIssue(camera, error: error) }
                // Closed/error streams are retried by the HomeKit client. Never log URL/auth headers.
                await self?.finish(id)
            }
        }
    }

    nonisolated private static func send(_ bytes: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func reply(_ id: UUID, status: Int, body: Data) {
        guard let connection = connections[id] else { return }
        var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Unavailable")\r\nContent-Type: image/jpeg\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.finish(id) }
        })
    }

    private func reportVideoIssue(_ camera: String, error: Error) {
        onVideoIssue?(camera, BridgeCameraIssue.classify(error))
    }

    private func finish(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        streamTasks.removeValue(forKey: id)?.cancel()
        deadlines.removeValue(forKey: id)?.cancel()
    }
}
