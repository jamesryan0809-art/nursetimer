import SwiftUI
import SwiftData
import NurseTimerCore
import NurseTimerModels

/// Board (spec §6.2): patient cards sorted by soonest due task, a global "Up Next"
/// strip, overdue pinned red, and tasks needing schedule repair pinned above
/// everything with an unmissable treatment.
struct BoardView: View {
    @Environment(NurseStore.self) private var store
    @Query private var patients: [Patient]
    @Query private var tasks: [CareTask]
    @Binding var roomFilter: String?
    @State private var addingPatient = false

    private var now: Date { .now }
    private var settings: AppSettings { store.settings() }

    private var activePatients: [Patient] { patients.filter { $0.isActive } }
    private var scheduledTasks: [CareTask] { tasks.filter { $0.patient?.isActive == true } }

    private var repairTasks: [CareTask] {
        scheduledTasks.filter { $0.scheduleType.isNeedsRepair }
    }

    /// Next 3 upcoming/overdue tasks across all patients.
    private var upNext: [CareTask] {
        scheduledTasks
            .filter { !$0.isPaused && !$0.scheduleType.isNeedsRepair && $0.nextDueAt != nil }
            .sorted { ($0.nextDueAt ?? .distantFuture) < ($1.nextDueAt ?? .distantFuture) }
            .prefix(3).map { $0 }
    }

    private var sortedPatients: [Patient] {
        let visible = roomFilter.map { r in activePatients.filter { $0.roomNumber == r } } ?? activePatients
        return visible.sorted { soonestDue($0) < soonestDue($1) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if activePatients.isEmpty {
                    ContentUnavailableView {
                        Label("No patients yet", systemImage: "bed.double")
                    } actions: {
                        Button("Add Patient") { addingPatient = true }
                    }
                } else {
                    boardList
                }
            }
            .navigationTitle("Board")
            .sheet(isPresented: $addingPatient) {
                NavigationStack { PatientFormView(patient: nil) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { PatientListView() } label: { Label("Patients", systemImage: "person.2") }
                }
                if roomFilter != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Show all") { roomFilter = nil }
                    }
                }
            }
        }
    }

    private var boardList: some View {
        List {
            if !repairTasks.isEmpty {
                Section {
                    ForEach(repairTasks) { task in
                        RepairRow(task: task) { store.editRequest = .repair(task) }
                    }
                } header: {
                    Label("Needs schedule repair", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if !upNext.isEmpty {
                Section("Up Next") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(upNext) { task in UpNextChip(task: task) }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            ForEach(sortedPatients) { patient in
                Section(patient.display) {
                    ForEach(orderedTasks(for: patient)) { task in
                        TaskRowView(task: task, now: now, settings: settings)
                            .taskSwipeActions(task: task, store: store)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Ordering

    private func soonestDue(_ patient: Patient) -> Date {
        (patient.tasks.compactMap { $0.isPaused ? nil : $0.nextDueAt }.min()) ?? .distantFuture
    }

    private func orderedTasks(for patient: Patient) -> [CareTask] {
        patient.tasks.sorted { lhs, rhs in
            // Overdue/needsRepair first, then by due time; PRN/paused last.
            let a = status(of: lhs, now: now, settings: settings)
            let b = status(of: rhs, now: now, settings: settings)
            if a.isAttention != b.isAttention { return a.isAttention && !b.isAttention }
            return (lhs.nextDueAt ?? .distantFuture) < (rhs.nextDueAt ?? .distantFuture)
        }
    }
}

private struct UpNextChip: View {
    let task: CareTask
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Rm \(task.patient?.roomNumber ?? "?")").font(.headline)
            Text(task.title).font(.caption).lineLimit(1)
            Text(DueText.string(for: task.nextDueAt)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(minWidth: 120, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct RepairRow: View {
    let task: CareTask
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text("Rm \(task.patient?.roomNumber ?? "?") · \(task.title)").font(.headline)
                    Text("Schedule couldn't be loaded — tap to fix").font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.red.opacity(0.08))
    }
}

/// Swipe actions shared by Board and Patient detail (spec §6.2).
private struct TaskSwipeActions: ViewModifier {
    let task: CareTask
    let store: NurseStore

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !task.scheduleType.isNeedsRepair {
                    Button {
                        store.markGivenOrDone(task)
                    } label: {
                        Label(task.kind == .medication ? "Given" : "Done", systemImage: "checkmark")
                    }.tint(.green)
                }
            }
            .swipeActions(edge: .trailing) {
                Button { store.editRequest = task.scheduleType.isNeedsRepair ? .repair(task) : .edit(task) } label: {
                    Label("Edit", systemImage: "pencil")
                }
                if !task.scheduleType.isNeedsRepair {
                    Button { store.snooze(task) } label: { Label("Snooze", systemImage: "zzz") }.tint(.indigo)
                    Button { store.setPaused(task, !task.isPaused) } label: {
                        Label(task.isPaused ? "Resume" : "Pause", systemImage: task.isPaused ? "play" : "pause")
                    }.tint(.gray)
                }
            }
    }
}

extension View {
    func taskSwipeActions(task: CareTask, store: NurseStore) -> some View {
        modifier(TaskSwipeActions(task: task, store: store))
    }
}
