import SwiftUI
import NurseTimerModels

/// A patient's task with its projected times for the day. Identity is model-derived.
struct PatientTaskLine: Identifiable {
    let id: UUID          // taskID
    let title: String
    let dosage: String?
    let isMedication: Bool
    let times: [Date]
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
                                   isMedication: f.isMedication, times: occs.map { $0.date }.sorted())
        }.sorted { ($0.times.first ?? .distantFuture) < ($1.times.first ?? .distantFuture) }
    }

    /// "0900 · 1700 · 0100" (military, per §6.2 example).
    static func timesText(_ times: [Date]) -> String {
        times.map { hhmm.string(from: $0) }.joined(separator: " · ")
    }
    private static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmm"
        return f
    }()
}

/// By-Patient row rendering (spec §6.2): title (+ dosage) and the day's times, styled as a
/// projection (lighter/italic). Shared by the Schedule tab and the patient-detail hub.
struct PatientTaskRow: View {
    let line: PatientTaskLine
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(line.title + (line.isMedication ? (line.dosage.map { " · \($0)" } ?? "") : ""))
                .font(.subheadline)
            Text(PatientScheduleBuilder.timesText(line.times))
                .font(.caption.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .italic()
        .foregroundStyle(.secondary)
    }
}
