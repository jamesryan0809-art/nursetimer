import SwiftUI
import SwiftData
import NurseTimerCore
import NurseTimerModels

/// Board (spec §6.2) — the primary patient entry point. Patient cards are tappable
/// (→ patient detail) while task rows keep their swipe actions; a global "Up Next" strip,
/// overdue pinned red, and schedule-repair tasks pinned above everything.
struct BoardView: View {
    @Environment(NurseStore.self) private var store
    @Query private var patients: [Patient]
    @Query private var tasks: [CareTask]
    @Binding var roomFilter: String?
    @State private var addingPatient = false
    @State private var showingSettings = false

    private var now: Date { .now }
    private var settings: AppSettings { store.settings() }

    private var activePatients: [Patient] { patients.filter { $0.isActive } }
    private var inactivePatients: [Patient] { patients.filter { !$0.isActive } }
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
                    // §7 empty state: one line + one button.
                    ContentUnavailableView {
                        Label("No patients yet", systemImage: "bed.double")
                    } actions: {
                        Button("Add Patient") { addingPatient = true }
                        if !inactivePatients.isEmpty {
                            NavigationLink { PatientListView() } label: {
                                Text("Inactive patients (\(inactivePatients.count))")
                            }
                        }
                    }
                } else {
                    boardList
                }
            }
            .navigationTitle("Board")
            .navigationDestination(for: Patient.self) { PatientDetailView(patient: $0) }
            .sheet(isPresented: $addingPatient) { NavigationStack { PatientFormView(patient: nil) } }
            .sheet(isPresented: $showingSettings) { SettingsView(settings: store.settings()) }
            .toolbar {
                if roomFilter != nil {
                    ToolbarItem(placement: .topBarLeading) { Button("Show all") { roomFilter = nil } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { addingPatient = true } label: { Label("Add Patient", systemImage: "plus") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Label("Settings", systemImage: "gear") }
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
                Section {
                    // Tapping the card body opens the patient; task-row swipes still act on tasks.
                    NavigationLink(value: patient) {
                        PatientCardHeader(patient: patient, now: now, settings: settings)
                    }
                    ForEach(orderedTasks(for: patient)) { task in
                        Button { store.taskDetailRequest = .init(task: task) } label: {
                            TaskRowView(task: task, now: now, settings: settings)
                        }
                        .buttonStyle(.plain)
                        .taskSwipeActions(task: task, store: store)
                    }
                }
            }

            // Inline Add Patient stays visible when the list is short.
            if activePatients.count <= 3 {
                Button { addingPatient = true } label: { Label("Add Patient", systemImage: "plus.circle") }
            }
            if !inactivePatients.isEmpty {
                NavigationLink { PatientListView() } label: {
                    Label("Inactive patients (\(inactivePatients.count))", systemImage: "archivebox")
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

private struct PatientCardHeader: View {
    let patient: Patient
    let now: Date
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(patient.display).font(.headline)
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        let n = patient.tasks.count
        let count = "\(n) task\(n == 1 ? "" : "s")"
        if let soonest = patient.tasks.compactMap({ $0.isPaused ? nil : $0.nextDueAt }).min() {
            return "\(count) · next \(DueText.string(for: soonest, now: now))"
        }
        return count
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

/// Swipe actions shared by Board and Patient detail (spec §6.2). Skip Once executes
/// immediately; Pause is always confirmed (naming task + room); paused tasks show Resume.
private struct TaskSwipeActions: ViewModifier {
    let task: CareTask
    let store: NurseStore
    @State private var confirmingPause = false

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
                    if task.isPaused {
                        Button { store.setPaused(task, false) } label: { Label("Resume", systemImage: "play") }.tint(.green)
                    } else {
                        Button { confirmingPause = true } label: { Label("Pause", systemImage: "pause") }.tint(.gray)
                        Button { store.snooze(task) } label: { Label("Snooze", systemImage: "zzz") }.tint(.indigo)
                        Button { store.skip(task, source: "in app") } label: { Label("Skip Once", systemImage: "forward") }.tint(.orange)
                    }
                }
            }
            .confirmationDialog("Pause this task?", isPresented: $confirmingPause, titleVisibility: .visible) {
                Button("Pause", role: .destructive) { store.pause(task, source: "in app") }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Rm \(task.patient?.roomNumber ?? "?") · \(task.title) — no reminders until you resume it.")
            }
    }
}

extension View {
    func taskSwipeActions(task: CareTask, store: NurseStore) -> some View {
        modifier(TaskSwipeActions(task: task, store: store))
    }
}
