import Foundation
import OSLog

/// Centralized loggers. Safety-relevant failures (scheduling, persistence,
/// notification registration) are logged here and surfaced in app state — never
/// silently dropped (Milestone 2 requirement).
enum AppLog {
    static let persistence = Logger(subsystem: "com.nursetimer.app", category: "persistence")
    static let notifications = Logger(subsystem: "com.nursetimer.app", category: "notifications")
    static let scheduling = Logger(subsystem: "com.nursetimer.app", category: "scheduling")
    static let ui = Logger(subsystem: "com.nursetimer.app", category: "ui")
}
