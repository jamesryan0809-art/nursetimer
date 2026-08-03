import Foundation
import NurseTimerCore
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Tiny shared bridge (App Group container) so the watch complication reads the SAME synced
/// snapshot the watch app received (BUILD_SPEC §5.1/§5.3). The watch app writes a compact summary
/// on every accepted snapshot; the widget's timeline provider reads it. No networking — an App
/// Group `UserDefaults` suite only, shared by the Watch app (writer) and Widget (reader).
enum ComplicationStore {
    static let appGroup = "group.com.nursetimer.app"
    private static let key = "nt.complication.v1"

    /// Everything the complication renders, derived from the snapshot so the widget needs no Core
    /// scheduling logic of its own.
    struct Summary: Codable, Equatable {
        var generatedAt: Date
        var overdueCount: Int
        var nextRoom: String?
        var nextTime: Date?
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func write(_ snapshot: SyncSnapshot) {
        let now = Date()
        // Only tasks that actually notify count toward the complication (parity with the planner).
        let active = snapshot.tasks.filter { !$0.isPaused && !$0.isArchived && $0.notificationsEnabled }
        let overdue = active.filter { ($0.nextDueAt ?? .distantFuture) <= now }.count
        let next = active
            .compactMap { task in task.nextDueAt.map { (task.room, $0) } }
            .filter { $0.1 > now }
            .min { $0.1 < $1.1 }
        let summary = Summary(generatedAt: snapshot.generatedAt, overdueCount: overdue,
                              nextRoom: next?.0, nextTime: next?.1)
        if let data = try? JSONEncoder().encode(summary) { defaults?.set(data, forKey: key) }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    static func read() -> Summary? {
        guard let data = defaults?.data(forKey: key),
              let summary = try? JSONDecoder().decode(Summary.self, from: data) else { return nil }
        return summary
    }

    /// Fresh if within the watch's 2h staleness threshold; older reads as not-synced on the face.
    static func isFresh(_ summary: Summary, now: Date = Date()) -> Bool {
        now.timeIntervalSince(summary.generatedAt) <= 2 * 3600
    }
}
