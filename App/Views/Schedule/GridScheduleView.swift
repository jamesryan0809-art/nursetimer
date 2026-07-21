import SwiftUI
import NurseTimerModels

/// Grid Schedule mode (item 1) — the paper-MAR mental model: columns are active patients
/// (room-headed), rows are 1-hour time blocks, and each projected occurrence is a compact
/// chip at its time×room intersection. Status coloring matches the Board; projections are
/// lighter. Tap a chip → the patient's detail. A "now" row is highlighted and auto-scrolled
/// into view. Same exclusions as the other modes (they come from `ScheduleProjector`).
struct GridScheduleView: View {
    let occurrences: [ScheduleOccurrence]
    let patients: [Patient]            // active, room-sorted
    let tasks: [CareTask]              // for status lookup
    let now: Date
    let settings: AppSettings

    private let cal = Calendar.autoupdatingCurrent
    private let timeColWidth: CGFloat = 56
    private let cellWidth: CGFloat = 96

    private struct GridKey: Hashable { let block: Date; let patient: String }

    private func hourBlock(_ date: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
    }

    private var nowBlock: Date { hourBlock(now) }

    /// Contiguous 1-hour rows spanning now → the last occurrence (capped).
    private var blocks: [Date] {
        let occBlocks = occurrences.map { hourBlock($0.date) }
        let start = min(nowBlock, occBlocks.min() ?? nowBlock)
        let end = max(nowBlock, occBlocks.max() ?? nowBlock)
        var out: [Date] = []
        var t = start
        while t <= end, out.count < 48 {
            out.append(t)
            t = cal.date(byAdding: .hour, value: 1, to: t) ?? end.addingTimeInterval(3600)
        }
        return out
    }

    private var byCell: [GridKey: [ScheduleOccurrence]] {
        Dictionary(grouping: occurrences) {
            GridKey(block: hourBlock($0.date), patient: $0.patientID?.uuidString ?? "detached")
        }
    }

    private var taskByID: [UUID: CareTask] {
        Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    }

    var body: some View {
        let cells = byCell
        let taskLookup = taskByID
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .topLeading, horizontalSpacing: 4, verticalSpacing: 4) {
                    // Header: room columns.
                    GridRow {
                        Color.clear.frame(width: timeColWidth, height: 1)
                        ForEach(patients) { p in
                            Text(p.roomNumber)
                                .font(.caption.bold()).lineLimit(1).truncationMode(.tail)
                                .frame(width: cellWidth)
                        }
                    }
                    ForEach(blocks, id: \.self) { block in
                        GridRow {
                            Text(AppTime.short(block))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(block == nowBlock ? Color.red : .secondary)
                                .frame(width: timeColWidth, alignment: .trailing)
                            ForEach(patients) { p in
                                cell(cells[GridKey(block: block, patient: p.id.uuidString)] ?? [],
                                     patient: p, taskLookup: taskLookup)
                            }
                        }
                        .background(block == nowBlock ? Color.red.opacity(0.06) : .clear)
                        .id(block)
                    }
                }
                .padding(8)
            }
            .onAppear { proxy.scrollTo(nowBlock, anchor: .center) }
        }
    }

    private func cell(_ occs: [ScheduleOccurrence], patient: Patient, taskLookup: [UUID: CareTask]) -> some View {
        VStack(spacing: 2) {
            ForEach(occs.sorted { $0.date < $1.date }) { occ in
                NavigationLink(value: patient) {
                    ChipView(occ: occ, status: chipStatus(occ, taskLookup: taskLookup), imminent: isImminent(occ, taskLookup: taskLookup))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: cellWidth, alignment: .top)
        .frame(minHeight: 26, alignment: .top)
    }

    private func isImminent(_ occ: ScheduleOccurrence, taskLookup: [UUID: CareTask]) -> Bool {
        guard let due = taskLookup[occ.taskID]?.nextDueAt else { return false }
        return abs(occ.date.timeIntervalSince(due)) < 60   // the actionable "next" occurrence
    }

    /// Status from the task for its imminent occurrence; later projections read as upcoming.
    private func chipStatus(_ occ: ScheduleOccurrence, taskLookup: [UUID: CareTask]) -> TaskStatus {
        guard let task = taskLookup[occ.taskID] else { return .upcoming }
        return isImminent(occ, taskLookup: taskLookup) ? status(of: task, now: now, settings: settings) : .upcoming
    }
}

/// A single occurrence chip. Status is the ONLY thing that tints it (red/orange/neutral);
/// projections (non-imminent) are lighter. A per-med color tag (item 2) is a separate
/// leading channel, added there.
private struct ChipView: View {
    let occ: ScheduleOccurrence
    let status: TaskStatus
    let imminent: Bool

    private var tint: Color {
        switch status {
        case .overdue, .needsRepair: return .red
        case .dueSoon: return .orange
        default: return .gray
        }
    }

    private var tag: TaskColorTag { TaskColorTag(rawValue: occ.colorTagRaw) ?? .none }

    var body: some View {
        HStack(spacing: 3) {
            // Tag channel (item 2) — a leading dot, SEPARATE from the status-driven background tint.
            TagDot(tag: tag, diameter: 6)
            Text(occ.title)
                .font(.caption2).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(tint.opacity(imminent ? 0.22 : 0.10), in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(imminent ? Color.primary : .secondary)
    }
}
