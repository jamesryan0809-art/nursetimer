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
        return due.formatted(date: .omitted, time: .shortened)
    }
}

extension Patient {
    /// "Rm 412B · Maria" (spec §3.1).
    var display: String { "Rm \(roomNumber)" + (firstName.map { " · \($0)" } ?? "") }
}
