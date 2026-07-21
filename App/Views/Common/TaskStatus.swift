import SwiftUI
import NurseTimerCore
import NurseTimerModels

/// Status is the ONLY thing color communicates (spec §7): red overdue, orange due-soon,
/// green done — plus the repair error treatment. Everything else is monochrome.
enum TaskStatus {
    case needsRepair
    case overdue
    case dueSoon
    case upcoming
    case paused
    case prn          // no automatic schedule

    var color: Color {
        switch self {
        case .needsRepair: return .red
        case .overdue:     return .red
        case .dueSoon:     return .orange
        case .upcoming:    return .primary
        case .paused:      return .secondary
        case .prn:         return .secondary
        }
    }

    var isAttention: Bool { self == .needsRepair || self == .overdue }
}

@MainActor
func status(of task: CareTask, now: Date, settings: AppSettings) -> TaskStatus {
    if task.scheduleType.isNeedsRepair { return .needsRepair }
    if task.isPaused { return .paused }
    guard let due = task.nextDueAt else { return .prn }
    if due <= now { return .overdue }
    let lead = task.leadTimeMinutes ?? settings.defaultLeadTimeMinutes
    if due <= now.addingTimeInterval(Double(lead) * 60) { return .dueSoon }
    return .upcoming
}

enum DueText {
    /// "12 min overdue" / "in 25 min" / "14:00" — glanceable, arm's-length legible.
    static func string(for due: Date?, now: Date = .now) -> String {
        guard let due else { return "PRN" }
        let delta = due.timeIntervalSince(now)
        let minutes = Int(abs(delta) / 60)
        if delta < 0 {
            if minutes < 60 { return "\(minutes) min overdue" }
            return "\(minutes / 60)h \(minutes % 60)m overdue"
        }
        if minutes < 60 { return "in \(minutes) min" }
        return AppTime.short(due)
    }
}

extension Patient {
    /// "Rm 412B · Maria" (spec §3.1).
    var display: String { "Rm \(roomNumber)" + (firstName.map { " · \($0)" } ?? "") }
}

/// PRN guidance (feedback item 3): the two facts a nurse needs to decide an as-needed dose —
/// when it was last given (live elapsed time) and the ordered frequency (free text). Both are
/// DISPLAY-ONLY: nothing here parses the frequency, computes a next-allowed time, validates, or
/// alerts — that would be dose-timing calculation (BUILD_SPEC §1.2 non-goal). The nurse reads
/// and decides.
struct PRNGuidanceView: View {
    let lastGiven: Date?
    let frequencyText: String
    /// Compact = single caption line for list rows; full = larger, for the task sheet.
    var compact = true

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 4) {
            // Live "Last given 1:07 PM · 2h ago" — re-renders each minute so elapsed stays fresh.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if let lastGiven {
                    Text("Last given \(AppTime.short(lastGiven)) · \(AppTime.relative(lastGiven, now: context.date))")
                } else {
                    Text("Not given yet")
                }
            }
            .font(compact ? .caption : .subheadline)
            .foregroundStyle(.secondary)

            if !frequencyText.isEmpty {
                Label(frequencyText, systemImage: "clock.arrow.circlepath")
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// "Muted is loud" (feedback item 2): a muted task must never be silently silent. This badge
/// is deliberately MONOCHROME (bold icon + label on a neutral capsule) so it stays unmissable
/// without borrowing a status hue — color remains status-only (spec §7).
struct MutedBadge: View {
    /// `false` shows just the bell-slash icon, for tight spots like Grid chips.
    var showsLabel = true

    var body: some View {
        if showsLabel {
            Label("Reminders off", systemImage: "bell.slash.fill")
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.primary)
                .accessibilityLabel("Reminders off")
        } else {
            Image(systemName: "bell.slash.fill")
                .font(.caption2)
                .foregroundStyle(.primary)
                .accessibilityLabel("Reminders off")
        }
    }
}
