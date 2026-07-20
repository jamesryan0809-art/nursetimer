import Foundation
import NurseTimerCore

/// Editable schedule state backing the Add/Edit form's picker. `mode == nil` means
/// "not chosen yet" — the state a repair starts in (schedule field empty & required).
struct ScheduleDraft {
    enum Mode: String, CaseIterable, Identifiable {
        case interval, fixed, once, prn
        var id: String { rawValue }
        var label: String {
            switch self {
            case .interval: "Every…"
            case .fixed: "At set times"
            case .once: "Once"
            case .prn: "PRN (as needed)"
            }
        }
    }

    var mode: Mode?
    var intervalHours = 0
    var intervalMinutes = 30
    var fixedTimes: [DateComponents] = [DateComponents(hour: 9, minute: 0)]
    var onceDate = Date().addingTimeInterval(3600)

    /// Whether the interval steppers currently form a legal interval (Core's bounds).
    var intervalIsValid: Bool { IntervalMinutes(hours: intervalHours, minutes: intervalMinutes) != nil }

    /// The Core `ScheduleType`, or nil when unset/invalid — the form disables Save on nil.
    var scheduleType: ScheduleType? {
        switch mode {
        case .interval: return ScheduleType.every(hours: intervalHours, minutes: intervalMinutes)
        case .fixed:    return fixedTimes.isEmpty ? nil : .fixedTimes(fixedTimes)
        case .once:     return .once(onceDate)
        case .prn:      return .prn
        case nil:       return nil
        }
    }

    /// Prefill from an existing valid schedule (edit flow). `.needsRepair` stays unset.
    static func from(_ schedule: ScheduleType) -> ScheduleDraft {
        var draft = ScheduleDraft()
        switch schedule {
        case .interval(let interval):
            draft.mode = .interval
            draft.intervalHours = interval.minutes / 60
            draft.intervalMinutes = interval.minutes % 60
        case .fixedTimes(let times):
            draft.mode = .fixed
            draft.fixedTimes = times.isEmpty ? [DateComponents(hour: 9, minute: 0)] : times
        case .once(let date):
            draft.mode = .once
            draft.onceDate = date
        case .prn:
            draft.mode = .prn
        case .needsRepair:
            draft.mode = nil
        }
        return draft
    }
}
