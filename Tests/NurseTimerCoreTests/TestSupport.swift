import Foundation
import XCTest
@testable import NurseTimerCore

// Deterministic calendar/date helpers. Every test pins an explicit time zone so
// results never depend on the machine running them.

func utcCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

func nyCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}

/// Build an absolute date from wall-clock components in the calendar's time zone.
func dt(_ cal: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    var c = DateComponents()
    c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
    return cal.date(from: c)!
}

func at(_ cal: Calendar, _ date: Date) -> DateComponents {
    cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
}

/// A minute-based `DateComponents` fixed time (only hour/minute matter).
func time(_ h: Int, _ m: Int) -> DateComponents {
    DateComponents(hour: h, minute: m)
}

/// Build a valid interval schedule for tests. Force-unwraps — callers pass legal values.
func everyHr(_ h: Int) -> ScheduleType { .interval(IntervalMinutes(hours: h)!) }
func everyMin(_ m: Int) -> ScheduleType { .interval(IntervalMinutes(minutes: m)!) }
