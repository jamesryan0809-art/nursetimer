import SwiftUI
import NurseTimerCore
import NurseTimerModels

/// One of a fixed-times task's occurrences for today, with its derived state (feedback pass 4,
/// item 2c). Derived live from the schedule's listed times + the single `nextDueAt` pointer —
/// nothing per-occurrence is persisted.
struct OccurrenceMark: Identifiable {
    enum State { case done, pending, upcoming }
    let time: Date
    let state: State
    let overdue: Bool
    var id: TimeInterval { time.timeIntervalSince1970 }
}

extension CareTask {
    /// Today's fixed-time occurrences with per-occurrence state, so the nurse can see at a glance
    /// which of e.g. 0900/1700/2100 is done. Empty for non-fixed schedules (single due time).
    ///
    /// State is pointer-relative: occurrences before `nextDueAt` are resolved (`.done`), the one
    /// at the pointer is `.pending` (overdue if the pointer is in the past), later ones are
    /// `.upcoming`. Occurrences earlier than the task's `createdAt` are omitted (the task didn't
    /// exist yet). "Done" means resolved — given, skipped, or acknowledged-missed; the Log and
    /// the Completed section carry the exact action.
    func todayOccurrences(now: Date = .now, calendar cal: Calendar = .autoupdatingCurrent) -> [OccurrenceMark] {
        guard case .fixedTimes(let comps) = scheduleType, !comps.isEmpty else { return [] }
        let pointer = nextDueAt
        var marks: [OccurrenceMark] = []
        for c in comps {
            guard let hour = c.hour,
                  let t = cal.date(bySettingHour: hour, minute: c.minute ?? 0, second: 0, of: now)
            else { continue }
            if t < createdAt { continue }   // task didn't exist for this slot yet
            let state: OccurrenceMark.State
            var overdue = false
            if let pointer {
                let delta = t.timeIntervalSince(pointer)
                if delta < -60 { state = .done }
                else if delta <= 60 { state = .pending; overdue = pointer < now }
                else { state = .upcoming }
            } else {
                state = .upcoming
            }
            marks.append(OccurrenceMark(time: t, state: state, overdue: overdue))
        }
        return marks.sorted { $0.time < $1.time }
    }
}

/// Renders a fixed-times task's day of occurrences as compact chips: done = struck + check,
/// pending = highlighted (red when overdue), upcoming = neutral. Status color stays reserved for
/// urgency; done/upcoming are monochrome so a tag/urgency reading is never confused (spec §7).
struct OccurrenceMarksView: View {
    let marks: [OccurrenceMark]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(marks) { mark in
                HStack(spacing: 3) {
                    Image(systemName: symbol(mark)).font(.caption2)
                    Text(AppTime.short(mark.time))
                        .font(.caption.monospacedDigit())
                        .strikethrough(mark.state == .done, color: .secondary)
                }
                .fontWeight(mark.state == .pending ? .semibold : .regular)
                .foregroundStyle(tint(mark))
            }
        }
    }

    private func symbol(_ mark: OccurrenceMark) -> String {
        switch mark.state {
        case .done:     return "checkmark.circle.fill"
        case .pending:  return mark.overdue ? "exclamationmark.circle.fill" : "circle.fill"
        case .upcoming: return "circle"
        }
    }

    private func tint(_ mark: OccurrenceMark) -> Color {
        switch mark.state {
        case .done:     return .secondary
        case .pending:  return mark.overdue ? .red : .primary
        case .upcoming: return .secondary
        }
    }
}
