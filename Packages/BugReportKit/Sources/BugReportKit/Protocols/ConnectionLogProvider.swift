import Foundation

/// Sanitized snapshot of a single HTTP request the host app made.
///
/// The host's actual log type usually has more — auth headers, full URLs,
/// hostnames — that should *never* leave the device, even to the on-device
/// LLM. The host produces values of this shape with secrets already stripped.
///
/// Path is expected to have query strings removed before getting here
/// (auth tokens often live there). Hostnames are not exposed at all.
public struct ConnectionLogEntryShape: Sendable, Hashable {
    public let timestamp: Date
    public let method: String
    public let path: String
    public let statusCode: Int?
    public let error: String?
    public let duration: TimeInterval

    public init(
        timestamp: Date,
        method: String,
        path: String,
        statusCode: Int?,
        error: String?,
        duration: TimeInterval
    ) {
        self.timestamp = timestamp
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.error = error
        self.duration = duration
    }
}

/// The host's HTTP request log, exposed to BugReportKit through one method.
///
/// Hosts implement this by wrapping their existing log type:
///
///     struct LumenConnectionLog: ConnectionLogProvider {
///         func entries() -> [ConnectionLogEntryShape] {
///             ConnectionLog.shared.entries().map { entry in
///                 // Strip query string — auth tokens may live there.
///                 let path = entry.path.split(separator: "?", maxSplits: 1)
///                                       .first.map(String.init) ?? entry.path
///                 return ConnectionLogEntryShape(
///                     timestamp: entry.timestamp,
///                     method: entry.method,
///                     path: path,
///                     statusCode: entry.statusCode,
///                     error: entry.error,
///                     duration: entry.duration
///                 )
///             }
///         }
///     }
public protocol ConnectionLogProvider: Sendable {
    /// Returns the most recent N log entries (host-defined cap).
    func entries() -> [ConnectionLogEntryShape]
}

/// No-op `ConnectionLogProvider`. Hosts that don't track HTTP requests (e.g.
/// CloudKit-only apps like Clasp, or apps that have their own opaque sync
/// layer) can use this directly so they don't have to write the boilerplate.
///
/// The package's `QueryConnectionLogTool` will see zero entries when given
/// this provider, which is fine — the AI adapts and asks the user when it
/// needs network context.
public struct EmptyConnectionLogProvider: ConnectionLogProvider {
    public init() {}
    public func entries() -> [ConnectionLogEntryShape] { [] }
}
