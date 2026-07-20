import Foundation
import NurseTimerCore
import NurseTimerModels

/// One projected future occurrence rendered on the Schedule tab. Projections are
/// computed from each task's schedule — they are NEVER persisted as task events.
struct ScheduleOccurrence: Identifiable {
    let id = UUID()
    let date: Date
    let taskID: UUID
    let room: String
    let firstName: String?
    let title: String
    let dosage: String?
    let isMedication: Bool
}

/// App-layer projection of the next 24 hours across all tasks, built on Core types
/// (`ScheduleType`, `IntervalMinutes`) without modifying Core. Excludes PRN, paused,
/// completed one-time, and `.needsRepair` tasks (spec §6.2).
enum ScheduleProjector {

    @MainActor
    static func occurrences(for tasks: [CareTask], from now: Date,
                            horizonHours: Double = 24, calendar: Calendar) -> [ScheduleOccurrence] {
        let end = now.addingTimeInterval(horizonHours * 3600)
        var result: [ScheduleOccurrence] = []

        for task in tasks where !task.isPaused {
            let schedule = task.scheduleType
            switch schedule {
            case .prn, .needsRepair:
                continue

            case .once(let date):
                if date >= now, date <= end { result.append(make(task, at: date)) }

            case .interval(let interval):
                guard var t = task.nextDueAt else { continue }
                let step = interval.timeInterval
                guard step > 0 else { continue }
                while t < now { t = t.addingTimeInterval(step) }   // roll an overdue anchor into the window
                var guardCounter = 0
                while t <= end, guardCounter < 500 {
                    result.append(make(task, at: t))
                    t = t.addingTimeInterval(step)
                    guardCounter += 1
                }

            case .fixedTimes(let times):
                for dayOffset in 0...1 {
                    guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
                    var comps = calendar.dateComponents([.year, .month, .day], from: day)
                    for time in times {
                        comps.hour = time.hour ?? 0
                        comps.minute = time.minute ?? 0
                        comps.second = 0
                        if let d = calendar.date(from: comps), d >= now, d <= end {
                            result.append(make(task, at: d))
                        }
                    }
                }
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    @MainActor
    private static func make(_ task: CareTask, at date: Date) -> ScheduleOccurrence {
        ScheduleOccurrence(
            date: date, taskID: task.id, room: task.patient?.roomNumber ?? "",
            firstName: task.patient?.firstName, title: task.title, dosage: task.dosage,
            isMedication: task.kind == .medication)
    }
}
