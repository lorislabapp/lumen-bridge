import Foundation

/// Categories for triaging user-submitted bug reports. Apple Intelligence
/// classifies the user's free-form description into one of these so we can
/// pre-fetch the right diagnostic context before the user finishes typing.
///
/// The cases are intentionally generic so the same enum works across the
/// LorisLabs portfolio — `streaming` covers both Lumen's MJPEG bugs and
/// Clasp's CloudKit-sync bugs (it's the network/connectivity bucket).
public enum BugCategory: String, Codable, CaseIterable, Sendable {
    case streaming
    case auth
    case notifications
    case recordings
    case events
    case ui
    case watch
    case widgets
    case other

    public var displayName: String {
        switch self {
        case .streaming:     return String(localized: "Live streams / images")
        case .auth:          return String(localized: "Login / authentication")
        case .notifications: return String(localized: "Push notifications")
        case .recordings:    return String(localized: "Recordings / clips")
        case .events:        return String(localized: "Events / detections")
        case .ui:            return String(localized: "App layout / navigation")
        case .watch:         return String(localized: "Apple Watch")
        case .widgets:       return String(localized: "Widgets")
        case .other:         return String(localized: "Other")
        }
    }
}

/// Severity hint surfaced to the developer in the email subject. Not promises
/// — the host triages internally — but lets us prioritize what to read first.
public enum BugSeverity: String, Codable, CaseIterable, Sendable {
    case critical
    case major
    case minor
    case question

    public var displayName: String {
        switch self {
        case .critical: return String(localized: "Critical")
        case .major:    return String(localized: "Major")
        case .minor:    return String(localized: "Minor")
        case .question: return String(localized: "Question")
        }
    }

    public var emoji: String {
        switch self {
        case .critical: return "🔴"
        case .major:    return "🟠"
        case .minor:    return "🟡"
        case .question: return "❔"
        }
    }
}

/// Specific diagnostic fields the AI triage may flag as "useful for this kind
/// of bug". The package auto-fills as many as it can from the host's tools;
/// the user only sees a follow-up form for fields that need their input.
public enum DiagnosticField: String, Codable, CaseIterable, Sendable {
    // Auto-fillable from host tools — no user prompt
    case appBuild
    case osVersion
    case deviceModel
    case frigateVersion
    case authMode
    case connectionScheme
    case lastApiCallStatus
    case isCellular
    case relayVersion
    case mqttConfigured

    // Need user input
    case lastWorkingDate
    case reproSteps
    case affectedCameras
    case proxySetup
    case attachScreenshot

    public var isAutoFillable: Bool {
        switch self {
        case .appBuild, .osVersion, .deviceModel, .frigateVersion, .authMode,
             .connectionScheme, .lastApiCallStatus, .isCellular,
             .relayVersion, .mqttConfigured:
            return true
        case .lastWorkingDate, .reproSteps, .affectedCameras, .proxySetup,
             .attachScreenshot:
            return false
        }
    }

    public var userPrompt: String? {
        switch self {
        case .lastWorkingDate:  return String(localized: "When did this last work correctly?")
        case .reproSteps:       return String(localized: "How can we reproduce it?")
        case .affectedCameras:  return String(localized: "Which cameras are affected?")
        case .proxySetup:       return String(localized: "Are you using a reverse proxy or tunnel?")
        case .attachScreenshot: return String(localized: "Can you attach a screenshot or screen recording?")
        default:                return nil
        }
    }
}

/// AI-classified result of a free-form bug description. When Apple
/// Intelligence is unavailable, the same shape is filled by
/// `BugTriageService.fallback` using simple keyword rules — so the rest of
/// the flow doesn't care which path produced it.
public struct BugTriage: Codable, Sendable, Equatable {
    public let category: BugCategory
    public let severity: BugSeverity
    public let infoNeeded: [DiagnosticField]
    public let suggestedFollowUp: String?

    public init(
        category: BugCategory,
        severity: BugSeverity,
        infoNeeded: [DiagnosticField],
        suggestedFollowUp: String?
    ) {
        self.category = category
        self.severity = severity
        self.infoNeeded = infoNeeded
        self.suggestedFollowUp = suggestedFollowUp
    }
}
