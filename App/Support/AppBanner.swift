import Foundation

/// A user-visible, non-fatal problem the app must surface rather than swallow
/// (spec: "do not silently drop safety-relevant failures"). Rendered as a banner.
struct AppBanner: Identifiable, Equatable {
    enum Level: Equatable { case info, warning, error }
    let id = UUID()
    let level: Level
    let message: String

    static func notificationsDenied() -> AppBanner {
        AppBanner(level: .warning,
                  message: "Reminders are off. NurseTimer works as a visual board, but it can't ping you. Enable notifications in Settings.")
    }
    static func planCoalesced(groupCount: Int) -> AppBanner {
        AppBanner(level: .info,
                  message: "Many tasks scheduled — \(groupCount) reminder group\(groupCount == 1 ? "" : "s") were combined to stay under the reminder limit.")
    }
    static func schedulingError(_ detail: String) -> AppBanner {
        AppBanner(level: .error, message: "Couldn't update reminders: \(detail)")
    }
    static func persistenceError(_ detail: String) -> AppBanner {
        AppBanner(level: .error, message: "Couldn't save: \(detail)")
    }
}
