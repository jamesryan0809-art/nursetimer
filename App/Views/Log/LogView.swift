import SwiftUI
import SwiftData
import NurseTimerModels

/// Log tab (spec §6.2): reverse-chronological TaskEvents, filterable by patient.
/// No export in this pass.
struct LogView: View {
    @Query(sort: \TaskEvent.timestamp, order: .reverse) private var events: [TaskEvent]
    @Query private var patients: [Patient]
    @State private var patientFilter: UUID?

    private var filtered: [TaskEvent] {
        guard let patientFilter else { return events }
        return events.filter { $0.task?.patient?.id == patientFilter }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    ContentUnavailableView("No history yet", systemImage: "list.bullet.rectangle",
                                           description: Text("Given, snoozed, and skipped actions appear here."))
                } else {
                    List(filtered) { event in LogRow(event: event) }
                        .listStyle(.plain)
                }
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("All patients") { patientFilter = nil }
                        Divider()
                        ForEach(patients.filter { $0.isActive }) { p in
                            Button(p.display) { patientFilter = p.id }
                        }
                    } label: {
                        Label("Filter", systemImage: patientFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
        }
    }
}

private struct LogRow: View {
    let event: TaskEvent
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline)
                if let note = event.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        let room = event.task?.patient?.roomNumber.map { "Rm \($0) · " } ?? ""
        let name = event.task?.title ?? "Task"
        return "\(actionWord) — \(room)\(name)"
    }
    private var actionWord: String {
        switch event.action {
        case .given: "Given"; case .done: "Done"; case .skipped: "Skipped"
        case .snoozed: "Snoozed"; case .missedAcknowledged: "Missed (ack)"; case .paused: "Paused"
        }
    }
    private var symbol: String {
        switch event.action {
        case .given, .done: "checkmark.circle.fill"
        case .skipped: "forward.circle.fill"
        case .snoozed: "zzz"
        case .missedAcknowledged: "exclamationmark.circle.fill"
        case .paused: "pause.circle.fill"
        }
    }
    private var color: Color {
        switch event.action {
        case .given, .done: .green
        case .skipped: .secondary
        case .snoozed: .indigo
        case .missedAcknowledged: .orange
        case .paused: .gray
        }
    }
}
