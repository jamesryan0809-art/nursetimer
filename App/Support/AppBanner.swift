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
    /// Early (pre-due) reminders were dropped — the workflow-critical class, called out
    /// specifically (feedback pass 5, item 4).
    var preAlertsTrimmed = false
    var coalesced = false
    var groupCount = 0
    /// Taper repeat-pings were shortened (not surfaced on its own — the nurse still keeps the
    /// pre-alert, due alert, and the 5-ping floor).
    var tailsTrimmed = false

    /// Surfaced only for reductions a nurse would care about: a dropped early reminder or
    /// grouped alerts. Tail-only trimming is not surfaced.
    var isActive: Bool { preAlertsTrimmed || coalesced }

    var headline: String {
        preAlertsTrimmed ? "Early reminders trimmed" : "Reminders grouped"
    }

    var detail: String {
        if preAlertsTrimmed {
            // The specific, discoverable message: a nurse relying on a 30-min ping must be able
            // to learn it was dropped (item 4).
            return "Some early reminders were trimmed to stay within iOS notification limits. Every task is still on your board and its due-time alert still fires — only the early heads-up was dropped, furthest-out doses first."
        }
        let groups = "\(groupCount) reminder group\(groupCount == 1 ? "" : "s")"
        return "Many tasks are scheduled, so \(groups) were combined to stay under the iOS notification limit. Every task is still on your board; early reminders and due alerts are unaffected."
    }
}
