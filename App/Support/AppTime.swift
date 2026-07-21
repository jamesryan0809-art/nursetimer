import Foundation

/// The single source of user-facing time formatting (item 3). Follows the device's locale
/// and 12h/24h setting via `.shortened` — never hardcodes a format. Sorting stays
/// chronological: callers sort `Date`s and only format for display.
enum AppTime {
    /// Short time only ("9:00 AM" or "09:00" per the device setting).
    static func short(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Abbreviated date + short time (Log timestamps).
    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// A middot-joined list of short times ("9:00 AM · 5:00 PM · 1:00 AM").
    static func shortList(_ dates: [Date]) -> String {
        dates.map(short).joined(separator: " · ")
    }
}
