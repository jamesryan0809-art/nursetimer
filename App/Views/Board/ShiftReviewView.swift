import SwiftUI
import SwiftData
import NurseTimerCore
import NurseTimerModels

/// Shift Review (spec §6.4). Steps through each active patient — Keep (with an optional
/// quick-edit of tasks/times), Discharge (soft-archives the patient: tasks excluded from
/// planning, notifications cancelled, history retained — never a hard delete), or Skip for now —
/// then ends with a summary. Discharged patients land in the inactive-patients Archive list
/// (restorable). Manual trigger only; the auto-prompt at `shiftStartHour` stays deferred.
struct ShiftReviewView: View {
    @Environment(NurseStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// The active patients captured when review began, so discharging one mid-review doesn't
    /// reshuffle the remaining steps.
    let patients: [Patient]

    @State private var index = 0
    @State private var keptCount = 0
    @State private var dischargedCount = 0
    @State private var now = Date()

    var body: some View {
        NavigationStack {
            Group {
                if index < patients.count {
                    reviewStep(for: patients[index])
                } else {
                    summary
                }
            }
            .navigationTitle("Shift Review")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(index < patients.count ? "Stop" : "Done") { dismiss() }
                }
                if index < patients.count {
                    ToolbarItem(placement: .principal) {
                        Text("\(index + 1) of \(patients.count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Per-patient step

    private func reviewStep(for patient: Patient) -> some View {
        let active = patient.tasks.filter { !$0.isArchived && !$0.isCompletedTerminal }
        return VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(patient.display).font(.title3.bold())
                Text("\(active.count) active task\(active.count == 1 ? "" : "s")")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let soonest = active.compactMap({ $0.isPaused ? nil : $0.nextDueAt }).min() {
                    Label("Next \(DueText.string(for: soonest, now: now))", systemImage: "clock")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            // Optional quick-edit of this patient's tasks/times before keeping.
            NavigationLink {
                PatientDetailView(patient: patient)
            } label: {
                Label("Review / edit tasks", systemImage: "pencil").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Spacer()

            VStack(spacing: 10) {
                Button {
                    keptCount += 1; advance()
                } label: {
                    Label("Keep", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .tint(.green)

                Button(role: .destructive) {
                    store.dischargePatient(patient)
                    dischargedCount += 1; advance()
                } label: {
                    Label("Discharge", systemImage: "figure.walk.departure").frame(maxWidth: .infinity)
                }

                Button {
                    advance()
                } label: {
                    Label("Skip for now", systemImage: "arrow.forward").frame(maxWidth: .infinity)
                }
                .tint(.secondary)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }

    // MARK: Summary

    private var summary: some View {
        let active = store.activePatients()
        let tasks = active.flatMap { $0.tasks }.filter { !$0.isArchived && !$0.isCompletedTerminal }
        let firstDue = tasks.compactMap { $0.isPaused ? nil : $0.nextDueAt }.min()
        return VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(.green)
            Text("Shift ready").font(.title3.bold())
            VStack(alignment: .leading, spacing: 8) {
                summaryRow("Active patients", "\(active.count)")
                summaryRow("Active tasks", "\(tasks.count)")
                summaryRow("First due", firstDue.map { DueText.string(for: $0, now: now) } ?? "—")
                if dischargedCount > 0 { summaryRow("Discharged", "\(dischargedCount)") }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            Text("Discharged patients move to the inactive Archive and can be restored.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding()
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.semibold) }
    }

    private func advance() {
        now = Date()
        index += 1
    }
}
