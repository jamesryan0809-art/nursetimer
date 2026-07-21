import SwiftUI
import NurseTimerModels

/// What the tap-to-act task sheet targets. Mirrors `TaskEditTarget` so the root can present
/// it centrally via `sheet(item:)`.
struct TaskDetailTarget: Identifiable {
    let task: CareTask
    var id: UUID { task.id }
}

/// Tap-to-act task detail (design pass, feedback item 1). Opened by tapping ANY task row —
/// Board, patient detail, Schedule list, or a Grid chip — so completing / snoozing / skipping
/// / pausing is no longer swipe-only. Large explicit buttons mirror the watch task-detail
/// layout. Swipe actions remain as shortcuts but are no longer the only path.
struct TaskDetailSheet: View {
    @Environment(NurseStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let task: CareTask

    @State private var confirmingPause = false
    @State private var editing = false

    private var settings: AppSettings { store.settings() }
    private var taskStatus: TaskStatus { status(of: task, now: .now, settings: settings) }
    private var needsRepair: Bool { task.scheduleType.isNeedsRepair }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    header

                    if needsRepair {
                        repairPrompt
                    } else {
                        actions
                    }
                }
                .padding()
            }
            .navigationTitle(task.patient.map { "Rm \($0.roomNumber)" } ?? "Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .confirmationDialog("Pause this task?", isPresented: $confirmingPause, titleVisibility: .visible) {
                Button("Pause", role: .destructive) { store.pause(task, source: "in app"); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Rm \(task.patient?.roomNumber ?? "?") · \(task.title) — no reminders until you resume it.")
            }
            .sheet(isPresented: $editing) {
                NavigationStack { TaskEditView(target: needsRepair ? .repair(task) : .edit(task)) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title).font(.title3.bold())
            if let detail = detailLine {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(dueLine).font(.headline.monospacedDigit()).foregroundStyle(taskStatus.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detailLine: String? {
        guard task.kind == .medication else { return nil }
        return [task.dosage, task.route].compactMap { $0 }.joined(separator: " · ").nilWhenEmpty
    }

    private var dueLine: String {
        switch taskStatus {
        case .needsRepair: return "Schedule needs repair"
        case .paused:      return "Paused"
        case .prn:         return "PRN · as needed"
        default:           return DueText.string(for: task.nextDueAt, now: .now)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if !task.notificationsEnabled { mutedBanner }

        Button {
            store.markGivenOrDone(task); dismiss()
        } label: {
            Label(task.kind == .medication ? "Given" : "Done", systemImage: "checkmark")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).tint(.green)

        Button {
            store.snooze(task); dismiss()
        } label: {
            Label("Snooze", systemImage: "zzz").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).tint(.indigo)

        Button {
            store.skip(task, source: "in app"); dismiss()
        } label: {
            Label("Skip Once", systemImage: "forward").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).tint(.orange)

        Divider().padding(.vertical, 4)

        if task.isPaused {
            Button {
                store.setPaused(task, false); dismiss()
            } label: {
                Label("Resume", systemImage: "play").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(.green)
        } else {
            Button(role: .destructive) {
                confirmingPause = true
            } label: {
                Label("Pause", systemImage: "pause").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }

        Button {
            editing = true
        } label: {
            Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    /// "Reminders off" shown prominently with a one-tap re-enable (feedback item 2). Silence
    /// must always be visible and easy to undo.
    private var mutedBanner: some View {
        VStack(spacing: 8) {
            Label("Reminders off — this task won't notify you.", systemImage: "bell.slash.fill")
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                store.setNotificationsEnabled(task, true)
            } label: {
                Label("Turn on reminders", systemImage: "bell").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var repairPrompt: some View {
        VStack(spacing: 12) {
            Label("This task's schedule couldn't be loaded. Fix it to restore reminders.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                editing = true
            } label: {
                Label("Fix schedule", systemImage: "wrench.and.screwdriver").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}
