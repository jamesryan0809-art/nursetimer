import Foundation

/// A user-visible, non-fatal problem the app must surface rather than swallow
/// (spec: "do not silently drop safety-relevant failures"). Rendered as a banner.
struct AppBanner: Identifiable, Equatable {
    enum Level: Equatable {
        case info, warning, error
        /// Higher rank wins: an error banner is never replaced by a lower-priority one (item 7).
        var rank: Int {
            switch self { case .info: 0; case .warning: 1; case .error: 2 }
        }
    }
    let id = UUID()
    let level: Level
    let message: String

    static func notificationsDenied() -> AppBanner {
        AppBanner(level: .warning,
                  message: "Reminders are off. NurseTimer works as a visual board, but it can't ping you. Enable notifications in Settings.")
    }
    static func schedulingError(_ detail: String) -> AppBanner {
        AppBanner(level: .error, message: "Couldn't update reminders: \(detail)")
    }
    /// The user's action could not be persisted and was NOT recorded (item 7).
    static let saveFailed = AppBanner(level: .error, message: "Couldn't save — action not recorded.")
    static func loadFailed(_ what: String) -> AppBanner {
        AppBanner(level: .error, message: "Couldn't load \(what).")
    }
}

/// An immediate, unmissable confirmation for a successful task action (feedback micro-pass):
/// a haptic + a brief auto-dismissing toast. Produced by the store only after a persisted
/// commit, so the message reflects real state. The unique `id` makes repeated identical actions
/// (e.g. Given twice) re-trigger the toast/haptic.
struct ActionAck: Identifiable, Equatable {
    /// Maps to a standard `UIFeedbackGenerator`: success/warning → notification haptics,
    /// light → a light impact.
    enum Style { case success, warning, light }
    let id = UUID()
    let message: String
    let style: Style
}

/// Non-blocking reminder-reduction indicator (feedback item 2). Reminders being reduced to fit
/// the OS budget is informational, not an error — so it no longer occupies the top banner
/// (which obstructed controls). This state drives a one-time-per-change alert and a persistent,
/// tappable nav-bar indicator instead. All tasks remain on the board regardless.
struct ReductionState: Equatable {
    var isActive = false
    var coalesced = false
    var groupCount = 0
    var trimmed = false

    var headline: String { "Reminders adjusted" }

    var detail: String {
        var parts: [String] = []
        if coalesced {
            parts.append("\(groupCount) reminder group\(groupCount == 1 ? "" : "s") combined")
        }
        if trimmed { parts.append("some early reminders trimmed") }
        let what = parts.isEmpty ? "some reminders were reduced" : parts.joined(separator: " and ")
        return "Many tasks are scheduled, so \(what) to stay under the reminder limit. Every task is still on your board — only the ping timing was adjusted."
    }
}
