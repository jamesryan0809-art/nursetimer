import Foundation

/// Pure next-due / reminder-timeline math. No storage, no notifications, no time
/// reads of its own — every entry point takes an explicit `now`/`completedAt`
/// and `Calendar` so behaviour is fully deterministic and unit-testable.
///
/// Mirrors spec §4.1 (next-due) and §4.2 (reminder timeline).
public enum SchedulingEngine {

    // MARK: Effective overrides

    /// Per-task lead override, else global default (spec §3.2 / §3.4).
    public static func effectiveLeadMinutes(_ task: SchedulableTask, _ settings: SchedulerSettings) -> Int {
        task.leadTimeMinutes ?? settings.defaultLeadTimeMinutes
    }

    /// Per-task snooze override, else global default (spec §3.2 / §3.4).
    public static func effectiveSnoozeMinutes(_ task: SchedulableTask, _ settings: SchedulerSettings) -> Int {
        task.snoozeMinutes ?? settings.defaultSnoozeMinutes
    }

    // MARK: Next due after completion (spec §4.1)

    /// The new `nextDueAt` after a task is marked Given/Done at `completedAt`.
    ///
    /// - `.interval`: anchored to the ACTUAL administration time (`completedAt`),
    ///   not the previous scheduled time — avoids drift-stacking (spec §4.1).
    /// - `.fixedTimes`: the next listed wall-clock time strictly after completion.
    /// - `.once`: nil — the task auto-pauses (see `shouldAutoPauseAfterCompletion`).
    /// - `.prn`: nil — never auto-schedules; only `lastCompletedAt` is updated by the caller.
    public static func nextDueAfterCompletion(
        schedule: ScheduleType,
        completedAt: Date,
        calendar: Calendar
    ) -> Date? {
        switch schedule {
        case .interval(let interval):
            return completedAt.addingTimeInterval(interval.timeInterval)
        case .fixedTimes(let times):
            return nextFixedTime(after: completedAt, times: times, calendar: calendar)
        case .once:
            return nil
        case .prn:
            return nil
        case .needsRepair:
            // A broken schedule produces no next-due. It must be repaired first.
            return nil
        }
    }

    /// A `.once` task holds itself after firing (spec §4.1).
    public static func shouldAutoPauseAfterCompletion(_ schedule: ScheduleType) -> Bool {
        if case .once = schedule { return true }
        return false
    }

    /// The **initial** `nextDueAt` for a freshly-set or just-repaired schedule,
    /// anchored at `anchor` (the nurse's last-given time, or now).
    ///
    /// Unlike `nextDueAfterCompletion`, `.once` yields its own fire date here (this
    /// is the *first* due, not the one after a completion). `.needsRepair` and
    /// `.prn` yield nil. Repair uses this to establish a fresh due time — the old,
    /// untrusted `nextDueAt` is never reused (spec §4.1 / §6.2).
    public static func firstDue(for schedule: ScheduleType, anchor: Date, calendar: Calendar) -> Date? {
        switch schedule {
        case .interval(let interval):
            return anchor.addingTimeInterval(interval.timeInterval)
        case .fixedTimes(let times):
            return nextFixedTime(after: anchor, times: times, calendar: calendar)
        case .once(let date):
            return date
        case .prn:
            return nil
        case .needsRepair:
            return nil
        }
    }

    // MARK: Fixed-time resolution (spec §4.1 / §8 midnight crossing)

    /// The earliest wall-clock time in `times` that falls strictly after `reference`,
    /// rolling to the next calendar day when all of today's times have passed.
    ///
    /// Only `hour` and `minute` of each `DateComponents` are used; seconds are 0.
    public static func nextFixedTime(
        after reference: Date,
        times: [DateComponents],
        calendar: Calendar
    ) -> Date? {
        guard !times.isEmpty else { return nil }

        var candidates: [Date] = []
        // Today and tomorrow is enough: if every time today is <= reference, one of
        // tomorrow's will be the next. Covers the midnight-crossing case (spec §8).
        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: reference) else { continue }
            var dayComps = calendar.dateComponents([.year, .month, .day], from: day)
            for time in times {
                dayComps.hour = time.hour ?? 0
                dayComps.minute = time.minute ?? 0
                dayComps.second = 0
                if let candidate = calendar.date(from: dayComps), candidate > reference {
                    candidates.append(candidate)
                }
            }
        }
        return candidates.min()
    }

    // MARK: Reminder timeline (spec §4.2)

    /// The pre-alert instant for a due time — `due − lead` (spec §4.2 step 1).
    public static func preAlertDate(due: Date, leadMinutes: Int) -> Date {
        due.addingTimeInterval(-Double(leadMinutes) * 60)
    }

    /// The re-ping snooze chain for an overdue/snoozed task (spec §4.2 step 3–4).
    ///
    /// Returns the next `count` pings of the form `anchor + k·S` (k ≥ 1) that fall
    /// strictly after `now`, paired with their chain index `k`. Because the window
    /// always slides forward past `now`, a long-overdue task still yields a full
    /// buffer of future pings — this is the "extend the chain" behaviour of §4.2
    /// step 3 expressed as a pure recompute.
    ///
    /// - For a naturally-overdue task, pass `anchor = dueDate`.
    /// - For an explicit Snooze, pass `anchor = the moment Snooze was tapped`
    ///   (first ping lands at `anchor + S`, i.e. `now + S`), per §4.2 step 4.
    public static func snoozeChain(
        anchor: Date,
        snoozeMinutes: Int,
        after now: Date,
        count: Int
    ) -> [(index: Int, date: Date)] {
        guard count > 0, snoozeMinutes > 0 else { return [] }
        let step = Double(snoozeMinutes) * 60

        // Smallest k ≥ 1 with anchor + k·step > now.
        var k = 1
        if anchor.addingTimeInterval(step) <= now {
            let elapsed = now.timeIntervalSince(anchor)
            k = max(1, Int((elapsed / step).rounded(.down)))
            // Nudge into the strictly-future region (guards float rounding).
            while anchor.addingTimeInterval(Double(k) * step) <= now { k += 1 }
        }

        var result: [(index: Int, date: Date)] = []
        result.reserveCapacity(count)
        for offset in 0..<count {
            let index = k + offset
            result.append((index, anchor.addingTimeInterval(Double(index) * step)))
        }
        return result
    }

    /// The tapered post-due re-ping chain (spec §4.2, item 3). Pure function of the
    /// anchor, snooze interval, `now`, the horizon, and the taper parameters — **no
    /// stored phase state**:
    ///
    /// - Phase 1: `fastCount` pings at the snooze interval `S` (anchor+S … anchor+fastCount·S).
    /// - Phase 2: `midCount` pings at `midIntervalMinutes`.
    /// - Phase 3: `slowIntervalMinutes` spacing to the horizon (the "indefinite" slow phase).
    ///
    /// Indices are 1-based positions from the anchor (stable regardless of `now`, so the
    /// identifiers survive re-plans). The returned pings are the subset strictly after
    /// `now` and at or before `horizonEnd` (the sliding window). Pass `anchor = dueDate`
    /// for a natural overdue task, or `anchor = the Snooze tap time` to re-anchor the
    /// whole taper at Phase 1 from the tap.
    public static func taperChain(
        anchor: Date,
        snoozeMinutes: Int,
        after now: Date,
        until horizonEnd: Date,
        settings: SchedulerSettings
    ) -> [(index: Int, date: Date)] {
        guard snoozeMinutes > 0 else { return [] }
        let s = Double(snoozeMinutes) * 60
        let mid = Double(settings.midIntervalMinutes) * 60
        let slow = Double(settings.slowIntervalMinutes) * 60

        var times: [Date] = []
        var t = anchor
        for _ in 0..<max(0, settings.fastCount) { t = t.addingTimeInterval(s); times.append(t) }
        for _ in 0..<max(0, settings.midCount) { t = t.addingTimeInterval(mid); times.append(t) }
        // Phase 3 to the horizon (bounded by a guard so a degenerate slow interval can't loop).
        var guardCount = 0
        while guardCount < 5000 {
            t = t.addingTimeInterval(slow)
            if t > horizonEnd { break }
            times.append(t)
            guardCount += 1
        }

        var result: [(index: Int, date: Date)] = []
        for (i, date) in times.enumerated() where date > now && date <= horizonEnd {
            result.append((index: i + 1, date: date))
        }
        return result
    }
}
