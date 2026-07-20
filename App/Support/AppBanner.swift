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
    /// Reminders were reduced to fit the budget — trimming and/or grouping (item 10).
    static func remindersReduced(coalesced: Bool, groupCount: Int) -> AppBanner {
        let detail = coalesced
            ? "\(groupCount) reminder group\(groupCount == 1 ? "" : "s") were combined"
            : "some early reminders were trimmed"
        return AppBanner(level: .info, message: "Many tasks scheduled — \(detail) to stay under the reminder limit.")
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
