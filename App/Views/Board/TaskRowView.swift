import SwiftUI
import NurseTimerModels

/// One task row. Room + title and due time are the largest elements (spec §7:
/// hierarchy by size). Color is a small status dot only.
struct TaskRowView: View {
    let task: CareTask
    let now: Date
    let settings: AppSettings

    private var taskStatus: TaskStatus { status(of: task, now: now, settings: settings) }

    var body: some View {
        HStack(spacing: 12) {
            // Tag channel (item 2) — separate from status; a thin left-edge bar, no tint on status.
            TagBar(tag: task.colorTag)

            Circle().fill(taskStatus.color).frame(width: 10, height: 10)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.headline)
                    .strikethrough(task.isPaused, color: .secondary)
                if let dosageLine {
                    Text(dosageLine).font(.subheadline).foregroundStyle(.secondary)
                }
                if task.isPRN {
                    PRNGuidanceView(lastGiven: task.lastCompletedAt, frequencyText: task.prnFrequencyText)
                }
                if !task.notificationsEnabled { MutedBadge() }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(dueLabel)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(taskStatus.color)
                if task.isPaused { Text("Paused").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title), \(dueLabel)")
    }

    private var dosageLine: String? {
        guard task.kind == .medication else { return nil }
        return [task.dosage, task.route].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    private var dueLabel: String {
        switch taskStatus {
        case .needsRepair: return "Fix"
        case .prn:         return "PRN"
        case .paused:      return "—"
        default:           return DueText.string(for: task.nextDueAt, now: now)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
