import Foundation

/// A calendar date with no time or time zone — the unit every due date,
/// payday and payment in Cashline is measured in.
///
/// Arithmetic is done on a day count (days since 1970-01-01, proleptic
/// Gregorian), so results never depend on the device time zone or DST.
public struct Day: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    /// 1...12
    public let month: Int
    /// 1...31
    public let day: Int

    /// Builds a date, rolling an out-of-range month into neighbouring years
    /// and clamping the day to the month's length (Jan 31 + 1 month = Feb 28/29).
    /// `monthIndex` is zero-based like JavaScript's `Date`, so `-1` is last
    /// December and `12` is next January.
    public static func clamped(year: Int, monthIndex: Int, day: Int) -> Day {
        let y = year + Int((Double(monthIndex) / 12).rounded(.down))
        let m0 = ((monthIndex % 12) + 12) % 12
        let dim = Day.daysInMonth(year: y, month: m0 + 1)
        return Day(uncheckedYear: y, month: m0 + 1, day: min(max(day, 1), dim))
    }

    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), day >= 1, day <= Day.daysInMonth(year: year, month: month) else { return nil }
        self.init(uncheckedYear: year, month: month, day: day)
    }

    private init(uncheckedYear year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    /// Today on the device's calendar.
    public static func today(calendar: Calendar = .current, now: Date = Date()) -> Day {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return Day(uncheckedYear: c.year!, month: c.month!, day: c.day!)
    }

    // MARK: parsing / formatting

    /// Parses `yyyy-MM-dd` (anything after the date, like a time, is ignored).
    public init?(iso: String) {
        let parts = iso.prefix(10).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// `yyyy-MM-dd`
    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    /// `yyyy-MM`, the billing-cycle key used by the web app.
    public var cycleKey: String { String(format: "%04d-%02d", year, month) }
    public var description: String { iso }

    /// Zero-based month, matching `Date.getMonth()` in the web app.
    public var monthIndex: Int { month - 1 }

    // MARK: arithmetic

    /// Days since 1970-01-01.
    public var ordinal: Int { Day.daysFromCivil(year, month, day) }

    public init(ordinal: Int) {
        let (y, m, d) = Day.civilFromDays(ordinal)
        self.init(uncheckedYear: y, month: m, day: d)
    }

    public func adding(days n: Int) -> Day { Day(ordinal: ordinal + n) }

    /// `other - self` in days.
    public func days(until other: Day) -> Int { other.ordinal - ordinal }

    /// 0 = Sunday … 6 = Saturday.
    public var weekday: Int { ((ordinal % 7) + 7 + 4) % 7 }

    public static func < (a: Day, b: Day) -> Bool { a.ordinal < b.ordinal }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Start of this day in the given calendar (for scheduling notifications).
    public func date(hour: Int = 0, calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
    }

    // Howard Hinnant's civil-date algorithms.
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    private static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}

extension Day: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = Day(iso: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected yyyy-MM-dd, got \(s)"))
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(iso)
    }
}

public enum DayText {
    public static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    public static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    public static let fullMonths = ["January", "February", "March", "April", "May", "June", "July",
                                    "August", "September", "October", "November", "December"]

    /// "Nov 7"
    public static func short(_ d: Day) -> String { "\(months[d.monthIndex]) \(d.day)" }

    /// "Due today", "Due in 3 days", "2 days overdue"
    public static func relative(_ n: Int) -> String {
        switch n {
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        case 2...: return "Due in \(n) days"
        default: return "\(-n) \(n == -1 ? "day" : "days") overdue"
        }
    }
}
