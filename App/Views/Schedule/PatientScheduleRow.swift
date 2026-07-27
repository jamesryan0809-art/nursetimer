import SwiftUI
import NurseTimerModels

/// A patient's task with its projected times for the day. Identity is model-derived.
struct PatientTaskLine: Identifiable {
    let id: UUID          // taskID
    let title: String
    let dosage: String?
    let isMedication: Bool
    let times: [Date]
    let colorTagRaw: String
    let muted: Bool
    /// True when this task has an unresolved overdue occurrence (feedback item 4) — the row is
    /// marked red and not dimmed as a projection.
    let isOverdue: Bool

    var colorTag: TaskColorTag { TaskColorTag(rawValue: colorTagRaw) ?? .none }
}

/// Builds By-Patient lines from the shared `ScheduleProjector` — the single source of
/// projection logic, reused by the Schedule tab AND the patient-detail hub (item 12/3).
enum PatientScheduleBuilder {
    @MainActor
    static func lines(for tasks: [CareTask], now: Date = .now,
                      calendar: Calendar = .autoupdatingCurrent) -> [PatientTaskLine] {
        lines(from: ScheduleProjector.occurrences(for: tasks, from: now, calendar: calendar))
    }

    static func lines(from occurrences: [ScheduleOccurrence]) -> [PatientTaskLine] {
        let byTask = Dictionary(grouping: occurrences) { $0.taskID }
        return byTask.map { _, occs -> PatientTaskLine in
            let f = occs[0]
            return PatientTaskLine(id: f.taskID, title: f.title, dosage: f.dosage,
                                   isMedication: f.isMedication, times: occs.map { $0.date }.sorted(),
                                   colorTagRaw: f.colorTagRaw, muted: f.muted,
                                   isOverdue: occs.contains { $0.isOverdue })
        }.sorted { ($0.times.first ?? .distantFuture) < ($1.times.first ?? .distantFuture) }
    }

    /// Device-locale short times joined ("9:00 AM · 5:00 PM · 1:00 AM"), item 3.
    static func timesText(_ times: [Date]) -> String { AppTime.shortList(times) }
}

/// By-Patient row rendering (spec §6.2): title (+ dosage) and the day's times, styled as a
/// projection (lighter/italic). Shared by the Schedule tab and the patient-detail hub.
struct PatientTaskRow: View {
    let line: PatientTaskLine
    /// Per-occurrence marks for a fixed-times task (feedback pass 4, item 2c); empty otherwise.
    var occurrences: [OccurrenceMark] = []

    var body: some View {
        HStack(spacing: 12) {
            TagBar(tag: line.colorTag, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if line.isOverdue {
                        Image(systemName: "exclamationmark.circle.fill").font(.caption)
                    }
                    Text(line.title + (line.isMedication ? (line.dosage.map { " · \($0)" } ?? "") : ""))
                        .font(.subheadline)
                }
                // Fixed-times: show which doses are done; otherwise the plain projected times.
                if occurrences.isEmpty {
                    Text(PatientScheduleBuilder.timesText(line.times))
                        .font(.caption.monospacedDigit())
                } else {
                    OccurrenceMarksView(marks: occurrences)
                }
                if line.muted { MutedBadge().italic(false) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Overdue rows are marked red and NOT dimmed as a projection (feedback item 4). The
        // occurrence marks carry their own per-chip color, so don't tint them here.
        .italic(!line.isOverdue && occurrences.isEmpty)
        .foregroundStyle(line.isOverdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
    }
}
