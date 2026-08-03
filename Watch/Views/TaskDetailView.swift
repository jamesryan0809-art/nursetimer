import SwiftUI

/// Task detail (spec §5.1). SNOOZE is the visually dominant / first action (spec §5.2), then
/// Given/Done, then Skip Once. **Pause is phone-only** (the established design), so it is absent
/// here. No skip reasons — the phone records only the source ("via watch").
struct TaskDetailView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: WatchTask

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header

                if model.isPending(task) {
                    Label("Syncing to iPhone…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Button {
                    model.snooze(task); dismiss()
                } label: {
                    Label("Snooze", systemImage: "zzz").frame(maxWidth: .infinity)
                }
                .tint(.indigo)

                Button {
                    model.given(task); dismiss()
                } label: {
                    Label(task.isMedication ? "Given" : "Done", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .tint(.green)

                Button {
                    model.skipOnce(task); dismiss()
                } label: {
                    Label("Skip Once", systemImage: "forward").frame(maxWidth: .infinity)
                }
                .tint(.orange)
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .navigationTitle("Rm \(task.room)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title).font(.headline)
            if let dosage = task.dosage { Text(dosage).font(.caption).foregroundStyle(.secondary) }
            if task.isMuted {
                Label("Reminders off", systemImage: "bell.slash.fill")
                    .font(.caption2).foregroundStyle(.primary)
            }
            if task.isPRN, let last = task.lastCompletedAt {
                Text("Last given \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if !task.prnFrequencyText.isEmpty {
                    Text(task.prnFrequencyText).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(task.dueText).font(.caption).foregroundStyle(task.status.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
