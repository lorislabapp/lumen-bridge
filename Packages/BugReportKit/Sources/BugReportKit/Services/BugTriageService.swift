import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "fr.lorislab.bugreportkit", category: "BugTriage")

/// Triages a free-form user bug description into a `BugTriage` struct.
///
/// Two paths:
///   • **Apple Intelligence** (iOS/macOS/visionOS 26+ with `SystemLanguageModel`
///     available) — the on-device LLM classifies via a system prompt and
///     few-shot examples.
///   • **Keyword-based fallback** — a deterministic, word-boundary classifier
///     used everywhere else.
///
/// Callers only see the `BugTriage` result; the triage path used is an
/// implementation detail.
public enum BugTriageService {

    /// Triage entry point. Returns a `BugTriage` no matter what — the caller
    /// never has to deal with "AI unavailable" branches.
    public static func triage(
        description: String,
        language: String = Locale.current.language.languageCode?.identifier ?? "en"
    ) async -> BugTriage {
        if let aiResult = await runAI(description: description, language: language) {
            return aiResult
        }
        return fallback(description: description)
    }

    // MARK: - Apple Intelligence path

    /// Few-shot system prompt: the model reads the examples and generalizes
    /// to similar phrasings. Tuning these examples is how triage quality
    /// improves without code changes. Hosts append their own framing via
    /// `BugReportContextProvider.domainSystemPromptAddendum`.
    private static let basePersona = """
    You triage bug reports for an iOS app. Given a user's free-form description,
    classify it as JSON.

    Output schema (respond with EXACTLY a single JSON object, no markdown fences):
    {
      "category": "streaming" | "auth" | "notifications" | "recordings" | "events" | "ui" | "watch" | "widgets" | "other",
      "severity": "critical" | "major" | "minor" | "question",
      "infoNeeded": [list from: appBuild, osVersion, deviceModel, frigateVersion, authMode, connectionScheme, lastApiCallStatus, isCellular, relayVersion, mqttConfigured, lastWorkingDate, reproSteps, affectedCameras, proxySetup, attachScreenshot],
      "suggestedFollowUp": "<one short polite question to ask the user, or null>"
    }

    Examples:

    User: "the streams won't load"
    {"category":"streaming","severity":"major","infoNeeded":["frigateVersion","authMode","connectionScheme","proxySetup","lastApiCallStatus"],"suggestedFollowUp":"Are you on the same WiFi or going through a tunnel?"}

    User: "notifications arrive 30 minutes late"
    {"category":"notifications","severity":"major","infoNeeded":["relayVersion","mqttConfigured","appBuild","lastApiCallStatus"],"suggestedFollowUp":"Could you share a sample of the late notification's timestamp vs the event time?"}

    User: "every clip says recording unavailable"
    {"category":"recordings","severity":"major","infoNeeded":["frigateVersion","affectedCameras","reproSteps"],"suggestedFollowUp":"Is the affected event recent or older?"}

    User: "the events tab is empty since today"
    {"category":"events","severity":"major","infoNeeded":["frigateVersion","lastApiCallStatus","lastWorkingDate"],"suggestedFollowUp":"Did you change anything in the server config recently?"}

    User: "the back arrow doesn't work after closing a clip"
    {"category":"ui","severity":"minor","infoNeeded":["appBuild","osVersion","deviceModel","reproSteps"],"suggestedFollowUp":null}

    User: "the watch app says no server"
    {"category":"watch","severity":"major","infoNeeded":["appBuild","osVersion","deviceModel"],"suggestedFollowUp":"Have you opened the iPhone app in the last 24 hours? The Watch syncs from there."}

    User: "is there a way to pick the high-quality stream?"
    {"category":"streaming","severity":"question","infoNeeded":[],"suggestedFollowUp":null}

    User: "app crashes when I add a second server"
    {"category":"ui","severity":"critical","infoNeeded":["appBuild","osVersion","deviceModel","reproSteps"],"suggestedFollowUp":"Does it crash on the Save button, or before?"}

    Be terse. The JSON is consumed by an app, not a human. Pick the closest
    category — never invent new ones. If the description is in another
    language, respond in English JSON regardless.
    """

    private static func runAI(description: String, language: String) async -> BugTriage? {
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, visionOS 26, *) else { return nil }
        let userPrompt = """
        Triage this user bug report (language: \(language)):

        \(description)

        Respond with the JSON only.
        """
        do {
            let session = LanguageModelSession(instructions: { basePersona })
            let response = try await session.respond(to: userPrompt)
            return parseTriage(response: response.content)
        } catch {
            logger.error("Foundation Models triage error: \(error.localizedDescription)")
            return nil
        }
        #else
        return nil
        #endif
    }

    private static func parseTriage(response: String) -> BugTriage? {
        var json = response
        json = json.replacingOccurrences(of: "```json", with: "")
        json = json.replacingOccurrences(of: "```", with: "")
        json = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = json.range(of: "{"), let end = json.range(of: "}", options: .backwards) {
            json = String(json[start.lowerBound...end.upperBound])
        }
        guard let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(BugTriage.self, from: data)
        } catch {
            logger.error("Failed to decode AI triage JSON: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Fallback (keyword-based, no AI)

    /// Used on devices without Apple Intelligence, or when Foundation Models
    /// rate-limits / errors out. Lower accuracy than the AI path but always
    /// returns *something* so the bug report flow doesn't blank-screen.
    public static func fallback(description: String) -> BugTriage {
        let lower = description.lowercased()
        let words: Set<String> = Set(
            lower
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )

        func has(_ keywords: [String]) -> Bool {
            for kw in keywords where words.contains(kw) { return true }
            return false
        }
        func phrase(_ phrases: [String]) -> Bool {
            for p in phrases where lower.contains(p) { return true }
            return false
        }

        let category: BugCategory = {
            // UI keywords first because they are highly specific ("crash",
            // "freeze", "button", "navigation") and would otherwise be hidden
            // by less specific category keywords appearing in the same
            // sentence (e.g. "the back button is broken after a clip").
            if has(["crash", "crashes", "freeze", "freezes", "hang", "hangs",
                    "layout", "navigation", "button"]) {
                return .ui
            }
            if has(["widget", "widgets"]) { return .widgets }
            if has(["watch", "watchos", "complication"]) { return .watch }
            if has(["login", "auth", "authentication", "password", "token",
                    "cookie", "cloudflare"]) { return .auth }
            if has(["notif", "notification", "notifications", "push", "alert",
                    "alerts", "late", "missed"]) { return .notifications }
            if has(["stream", "streams", "image", "images", "snapshot",
                    "snapshots", "mjpeg", "live"]) || phrase(["camera not"]) {
                return .streaming
            }
            if has(["clip", "clips", "record", "records", "recording",
                    "recordings", "playback", "video", "videos", "purged"]) {
                return .recordings
            }
            if has(["event", "events", "detect", "detection", "detections"]) {
                return .events
            }
            return .other
        }()

        let severity: BugSeverity = {
            if has(["crash", "crashes", "crashed", "crashing",
                    "freeze", "freezes", "froze", "frozen",
                    "hang", "hangs", "hung",
                    "stuck"])
                || phrase(["can't", "cannot", "won't connect", "data loss"]) {
                return .critical
            }
            if lower.hasPrefix("how do") || lower.hasPrefix("how can")
                || lower.hasPrefix("is there")
                || (lower.contains("?") && lower.count < 100) {
                return .question
            }
            if has(["late", "missing", "broken"])
                || phrase(["not working", "doesn't work"]) {
                return .major
            }
            return .minor
        }()

        let infoNeeded: [DiagnosticField] = {
            switch category {
            case .streaming:     return [.frigateVersion, .authMode, .connectionScheme, .proxySetup, .lastApiCallStatus]
            case .auth:          return [.frigateVersion, .authMode, .proxySetup, .connectionScheme]
            case .notifications: return [.relayVersion, .mqttConfigured, .appBuild, .lastApiCallStatus]
            case .recordings:    return [.frigateVersion, .affectedCameras, .reproSteps]
            case .events:        return [.frigateVersion, .lastApiCallStatus, .lastWorkingDate]
            case .ui:            return [.appBuild, .osVersion, .deviceModel, .reproSteps]
            case .watch:         return [.appBuild, .osVersion, .deviceModel]
            case .widgets:       return [.appBuild, .osVersion, .deviceModel]
            case .other:         return [.appBuild, .osVersion, .deviceModel, .reproSteps]
            }
        }()

        return BugTriage(category: category, severity: severity, infoNeeded: infoNeeded, suggestedFollowUp: nil)
    }

    /// Whether the AI path is available on this device.
    public static var aiIsAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, visionOS 26, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }
}
