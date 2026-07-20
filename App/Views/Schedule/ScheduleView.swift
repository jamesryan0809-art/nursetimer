import SwiftUI
import SwiftData
import NurseTimerModels

/// Schedule tab (spec §6.2): the next 24 hours of projected occurrences, grouped by
/// hour, with cluster highlighting. Read-only. Projections are computed live and are
/// never persisted as task events; PRN / paused / completed-once / needsRepair are
/// excluded by `ScheduleProjector`.
struct ScheduleView: View {
    @Environment(NurseStore.self) private var store
    @Query private var tasks: [CareTask]

    private var occurrences: [ScheduleOccurrence] {
        ScheduleProjector.occurrences(
            for: tasks.filter { $0.patient?.isActive == true },
            from: .now, calendar: .autoupdatingCurrent)
    }

    private var byHour: [(hour: String, items: [ScheduleOccurrence])] {
        let cal = Calendar.autoupdatingCurrent
        let groups = Dictionary(grouping: occurrences) { occ -> Date in
            var c = cal.dateComponents([.year, .month, .day, .hour], from: occ.date)
            c.minute = 0; c.second = 0
            return cal.date(from: c) ?? occ.date
        }
        return groups.keys.sorted().map { key in
            (hour: key.formatted(.dateTime.hour().minute()), items: groups[key]!.sorted { $0.date < $1.date })
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if occurrences.isEmpty {
                    ContentUnavailableView("Nothing scheduled", systemImage: "calendar",
                                           description: Text("Projected doses for the next 24 hours will appear here."))
                } else {
                    List {
                        ForEach(byHour, id: \.hour) { group in
                            Section {
                                if isCluster(group.items) {
                                    ClusterBadge(items: group.items)
                                }
                                ForEach(group.items) { occ in OccurrenceRow(occ: occ) }
                            } header: {
                                Text(group.hour).font(.headline)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Schedule")
        }
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
            Text(occ.date.formatted(date: .omitted, time: .shortened))
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
