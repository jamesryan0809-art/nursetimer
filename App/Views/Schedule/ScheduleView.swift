import SwiftUI
import SwiftData
import NurseTimerModels

/// Schedule tab (spec §6.2): the next 24 hours of projected occurrences, grouped by
/// hour, with cluster highlighting. Read-only. Projections are computed live and are
/// never persisted as task events; PRN / paused / completed-once / needsRepair are
/// excluded by `ScheduleProjector`.
enum ScheduleMode: String, CaseIterable { case byTime = "By Time", byPatient = "By Patient" }

/// A patient's projected day, for the By-Patient view. Identities are model-derived.
/// (`PatientTaskLine` / `PatientTaskRow` are shared in PatientScheduleRow.swift.)
private struct PatientDay: Identifiable {
    let id: String                // patientID (or a stable "detached" key)
    let label: String
    let tasks: [PatientTaskLine]
    var soonest: Date { tasks.first?.times.first ?? .distantFuture }
}

struct ScheduleView: View {
    @Environment(NurseStore.self) private var store
    @Query private var tasks: [CareTask]
    @State private var mode: ScheduleMode = .byTime

    private var occurrences: [ScheduleOccurrence] {
        ScheduleProjector.occurrences(
            for: tasks.filter { $0.patient?.isActive == true },
            from: .now, calendar: .autoupdatingCurrent)
    }

    private var byHour: [(bucket: Date, label: String, items: [ScheduleOccurrence])] {
        let cal = Calendar.autoupdatingCurrent
        let groups = Dictionary(grouping: occurrences) { occ -> Date in
            var c = cal.dateComponents([.year, .month, .day, .hour], from: occ.date)
            c.minute = 0; c.second = 0
            return cal.date(from: c) ?? occ.date
        }
        return groups.keys.sorted().map { key in
            // Identity is the hour-bucket Date (unique across dates); label is display only.
            (bucket: key, label: AppTime.short(key),
             items: groups[key]!.sorted { $0.date < $1.date })
        }
    }

    /// The same projections grouped by patient — the routing view (spec §6.2), e.g.
    /// "Rm 412 · Metoprolol: 0900 · 1700 · 0100". Same exclusions and source data.
    private var byPatient: [PatientDay] {
        let byPat = Dictionary(grouping: occurrences) { $0.patientID?.uuidString ?? "detached-\($0.room)" }
        return byPat.map { key, occs -> PatientDay in
            let first = occs[0]
            let label = "Rm \(first.room)" + (first.firstName.map { " · \($0)" } ?? "")
            return PatientDay(id: key, label: label, tasks: PatientScheduleBuilder.lines(from: occs))
        }.sorted { $0.soonest < $1.soonest }
    }

    var body: some View {
        NavigationStack {
            Group {
                if occurrences.isEmpty {
                    ContentUnavailableView("Nothing scheduled", systemImage: "calendar",
                                           description: Text("Projected doses for the next 24 hours will appear here."))
                } else if mode == .byTime {
                    byTimeList
                } else {
                    byPatientList
                }
            }
            .navigationTitle("Schedule")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(ScheduleMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private var byTimeList: some View {
        List {
            ForEach(byHour, id: \.bucket) { group in
                Section {
                    if isCluster(group.items) { ClusterBadge(items: group.items) }
                    ForEach(group.items) { occ in OccurrenceRow(occ: occ) }
                } header: {
                    Text(group.label).font(.headline)
                }
            }
        }
        .listStyle(.plain)
    }

    private var byPatientList: some View {
        List {
            ForEach(byPatient) { day in
                Section(day.label) {
                    ForEach(day.tasks) { line in PatientTaskRow(line: line) }
                }
            }
        }
        .listStyle(.plain)
    }

    /// 3+ tasks within a 15-minute window inside this hour bucket = a crunch point.
    private func isCluster(_ items: [ScheduleOccurrence]) -> Bool {
        guard items.count >= 3 else { return false }
        for i in items.indices {
            let windowEnd = items[i].date.addingTimeInterval(15 * 60)
            let count = items.filter { $0.date >= items[i].date && $0.date < windowEnd }.count
            if count >= 3 { return true }
        }
        return false
    }
}

private struct OccurrenceRow: View {
    let occ: ScheduleOccurrence
    var body: some View {
        HStack(spacing: 12) {
            Text(AppTime.short(occ.date))
                .font(.subheadline.monospacedDigit())
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text("Rm \(occ.room) · \(occ.title)").font(.subheadline)
                if let dosage = occ.dosage, occ.isMedication {
                    Text(dosage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        // Projections are rendered lighter/italic to distinguish from actual events.
        .italic()
        .foregroundStyle(.secondary)
    }
}


private struct ClusterBadge: View {
    let items: [ScheduleOccurrence]
    var body: some View {
        let rooms = Set(items.map(\.room)).count
        Label("\(items.count) tasks · \(rooms) room\(rooms == 1 ? "" : "s")", systemImage: "exclamationmark.circle")
            .font(.caption.bold())
            .foregroundStyle(.orange)
    }
}
