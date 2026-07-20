import SwiftUI
import NurseTimerCore

/// Schedule picker (spec §6.2). The interval mode is hours+minutes constrained to
/// [5 minutes, 24 hours] so invalid values are unenterable — `IntervalMinutes` is the
/// backstop. When `requireSelection` is true (repair flow) the mode starts unset.
struct SchedulePickerView: View {
    @Binding var draft: ScheduleDraft
    var requireSelection: Bool

    var body: some View {
        Section("Schedule") {
            Picker("Repeats", selection: Binding(
                get: { draft.mode },
                set: { draft.mode = $0 })
            ) {
                if requireSelection && draft.mode == nil {
                    Text("Choose…").tag(ScheduleDraft.Mode?.none)
                }
                ForEach(ScheduleDraft.Mode.allCases) { mode in
                    Text(mode.label).tag(ScheduleDraft.Mode?.some(mode))
                }
            }

            switch draft.mode {
            case .interval: intervalControls
            case .fixed:    fixedControls
            case .once:     DatePicker("At", selection: $draft.onceDate)
            case .prn:      Text("No automatic reminders. Give as needed.").font(.footnote).foregroundStyle(.secondary)
            case nil:       Text("A schedule is required.").font(.footnote).foregroundStyle(.red)
            }
        }
    }

    // MARK: Interval — bounded so 0/negatives/over-24h/under-5m are unreachable

    private var intervalControls: some View {
        Group {
            Stepper("Hours: \(draft.intervalHours)", value: $draft.intervalHours, in: 0...24)
            Stepper("Minutes: \(draft.intervalMinutes)", value: $draft.intervalMinutes, in: 0...55, step: 5)
            if !draft.intervalIsValid {
                Text("Interval must be between 5 minutes and 24 hours.")
                    .font(.footnote).foregroundStyle(.red)
            } else {
                Text("Every \(intervalSummary).").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onChange(of: draft.intervalHours) { _, _ in clampInterval() }
        .onChange(of: draft.intervalMinutes) { _, _ in clampInterval() }
    }

    private var intervalSummary: String {
        let h = draft.intervalHours, m = draft.intervalMinutes
        switch (h, m) {
        case (0, let m): return "\(m) min"
        case (let h, 0): return "\(h) h"
        default: return "\(h) h \(m) min"
        }
    }

    /// Keep the steppers inside legal territory: never allow 0h0m..<5m, never >24h00m.
    private func clampInterval() {
        if draft.intervalHours == 24 { draft.intervalMinutes = 0 }
        if draft.intervalHours == 0 && draft.intervalMinutes < 5 { draft.intervalMinutes = 5 }
    }

    // MARK: Fixed times

    private var fixedControls: some View {
        Group {
            ForEach(Array(draft.fixedTimes.enumerated()), id: \.offset) { index, _ in
                DatePicker("Time \(index + 1)",
                           selection: bindingForFixedTime(index),
                           displayedComponents: .hourAndMinute)
            }
            .onDelete { draft.fixedTimes.remove(atOffsets: $0) }
            Button {
                draft.fixedTimes.append(DateComponents(hour: 12, minute: 0))
            } label: { Label("Add time", systemImage: "plus") }
        }
    }

    private func bindingForFixedTime(_ index: Int) -> Binding<Date> {
        Binding(
            get: {
                let cal = Calendar.autoupdatingCurrent
                let comps = draft.fixedTimes[index]
                return cal.date(from: DateComponents(year: 2000, month: 1, day: 1,
                                                     hour: comps.hour ?? 0, minute: comps.minute ?? 0)) ?? .now
            },
            set: { newDate in
                let comps = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: newDate)
                draft.fixedTimes[index] = DateComponents(hour: comps.hour, minute: comps.minute)
            })
    }
}
