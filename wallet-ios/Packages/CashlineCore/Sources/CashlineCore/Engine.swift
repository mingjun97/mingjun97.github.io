import Foundation

// Read-only calculations over an AppState: due dates, deposit schedules,
// running-balance projections and calendar markers. A line-for-line port of
// the web app's logic; every function takes `today` so it can be tested.

public struct DueInfo: Hashable, Sendable {
    public var date: Day
    /// Billing-cycle key (`yyyy-MM`).
    public var key: String
    /// Days from today (negative when overdue).
    public var days: Int
    public var overdue: Bool
}

public struct UpcomingBill: Identifiable, Hashable, Sendable {
    public var bill: Bill
    public var due: DueInfo
    public var id: String { bill.id }
}

public struct UpcomingScheduled: Identifiable, Hashable, Sendable {
    public var payment: ScheduledPayment
    public var date: Day
    public var days: Int
    public var id: String { payment.id }
}

public struct DepositOccurrence: Hashable, Sendable {
    public var date: Day
    public var days: Int
    /// A one-off whose date has passed but hasn't been marked received.
    public var awaiting: Bool
}

public struct UpcomingDeposit: Identifiable, Hashable, Sendable {
    public var deposit: Deposit
    public var occurrence: DepositOccurrence
    public var id: String { deposit.id + ":" + occurrence.date.iso }
}

public struct Projection: Hashable, Sendable {
    /// Total going out in the window.
    public var outflow: Double
    /// Total expected in.
    public var inflow: Double
    /// Balance at the end of the window.
    public var end: Double
    /// Lowest running balance and when it happens.
    public var minimum: Double
    public var minimumDate: Day
    public var dipsBelowZero: Bool { minimum < -0.005 }
}

public struct AccountProjection: Identifiable, Hashable, Sendable {
    public var account: Account
    public var projection: Projection
    public var id: String { account.id }
}

/// Running balance around one timeline item.
public struct BalanceStep: Hashable, Sendable {
    public var before: Double
    public var after: Double
}

/// Key that identifies one item on the timeline (for `projections`).
public enum TimelineKey: Hashable, Sendable {
    case bill(String)
    case scheduled(String)
    case deposit(String, Day)
}

public enum CalendarMarker: Int, Comparable, Sendable, CaseIterable {
    case overdue = 0, manual, scheduled, deposit, autopayOrPaid
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .overdue: return "Overdue"
        case .manual: return "Manual pay"
        case .scheduled: return "Scheduled"
        case .deposit: return "Deposit"
        case .autopayOrPaid: return "Autopay / paid"
        }
    }
}

public struct Engine: Sendable {
    public var state: AppState
    public var today: Day

    public init(state: AppState, today: Day) {
        self.state = state
        self.today = today
    }

    // MARK: bills

    /// Cycle key of the most recent occurrence strictly before today. New bills
    /// start with this as `lastPaidCycle` so they aren't born overdue.
    public static func initialPaidCycle(dueDay: Int, today t: Day) -> String {
        for i in stride(from: 0, through: -1, by: -1) {
            let d = Day.clamped(year: t.year, monthIndex: t.monthIndex + i, day: dueDay)
            if d < t { return d.cycleKey }
        }
        return Day.clamped(year: t.year, monthIndex: t.monthIndex - 2, day: dueDay).cycleKey
    }

    public func scheduled(forBill billId: String, cycle: String) -> ScheduledPayment? {
        state.scheduled.first { $0.billId == billId && $0.cycle == cycle }
    }

    /// Next unpaid due date. Manual bills stay put (overdue) until marked paid;
    /// autopay bills are assumed paid on their due date and roll forward.
    public func nextDue(_ bill: Bill) -> DueInfo {
        let t = today
        for i in -2...3 {
            let d = Day.clamped(year: t.year, monthIndex: t.monthIndex + i, day: bill.dueDay)
            let key = d.cycleKey
            if let paid = bill.lastPaidCycle, paid >= key { continue }
            if scheduled(forBill: bill.id, cycle: key) != nil { continue }
            if d >= t { return DueInfo(date: d, key: key, days: t.days(until: d), overdue: false) }
            if !bill.autopay { return DueInfo(date: d, key: key, days: t.days(until: d), overdue: true) }
        }
        let d = Day.clamped(year: t.year, monthIndex: t.monthIndex + 4, day: bill.dueDay)
        return DueInfo(date: d, key: d.cycleKey, days: t.days(until: d), overdue: false)
    }

    /// Bills overdue or due within `window` days, soonest first.
    public func upcomingBills(within window: Int) -> [UpcomingBill] {
        state.bills.map { UpcomingBill(bill: $0, due: nextDue($0)) }
            .filter { $0.due.overdue || $0.due.days <= window }
            .sorted { ($0.due.date, $0.bill.name) < ($1.due.date, $1.bill.name) }
    }

    /// Every bill with its next due date, soonest first.
    public func allBillsByDue() -> [UpcomingBill] {
        state.bills.map { UpcomingBill(bill: $0, due: nextDue($0)) }
            .sorted { ($0.due.date, $0.bill.name) < ($1.due.date, $1.bill.name) }
    }

    /// The most recent due date strictly before today, if within two months.
    public func lastPassedDueKey(_ bill: Bill) -> String? {
        for i in stride(from: 0, through: -2, by: -1) {
            let d = Day.clamped(year: today.year, monthIndex: today.monthIndex + i, day: bill.dueDay)
            if d < today { return d.cycleKey }
        }
        return nil
    }

    // MARK: scheduled payments

    public func upcomingScheduled(within window: Int) -> [UpcomingScheduled] {
        state.scheduled.map { s -> UpcomingScheduled in
            let d = s.day ?? today
            return UpcomingScheduled(payment: s, date: d, days: today.days(until: d))
        }
        .filter { $0.days <= window }
        .sorted { ($0.date, $0.payment.name) < ($1.date, $1.payment.name) }
    }

    // MARK: deposits

    /// Occurrences within the next `window` days. Payroll rolls forward on its
    /// own; a one-off past its date stays listed (awaiting) until received.
    public func occurrences(of dep: Deposit, within window: Int) -> [DepositOccurrence] {
        let t = today, end = t.adding(days: window)
        var occ: [DepositOccurrence] = []
        func add(_ d: Day) { occ.append(DepositOccurrence(date: d, days: t.days(until: d), awaiting: false)) }

        if dep.type == .oneoff {
            if let d = dep.date.flatMap(Day.init(iso:)), d <= end {
                occ.append(DepositOccurrence(date: d, days: t.days(until: d), awaiting: d < t))
            }
            return occ
        }
        switch dep.cadence ?? .biweekly {
        case .weekly, .biweekly:
            let step = dep.cadence == .weekly ? 7 : 14
            guard var d = dep.anchor.flatMap(Day.init(iso:)) else { return occ }
            if d < t { d = d.adding(days: ((d.days(until: t) + step - 1) / step) * step) }
            while d <= end { add(d); d = d.adding(days: step) }
        case .monthly:
            for i in 0...2 {
                let d = Day.clamped(year: t.year, monthIndex: t.monthIndex + i, day: dep.day1 ?? 1)
                if d >= t && d <= end { add(d) }
            }
        case .semimonthly:
            for i in 0...2 {
                for day in [dep.day1 ?? 15, dep.day2 ?? 31] {
                    let d = Day.clamped(year: t.year, monthIndex: t.monthIndex + i, day: day)
                    if d >= t && d <= end { add(d) }
                }
            }
            occ.sort { $0.date < $1.date }
        }
        return occ
    }

    public func upcomingDeposits(within window: Int) -> [UpcomingDeposit] {
        state.deposits.flatMap { dep in occurrences(of: dep, within: window).map { UpcomingDeposit(deposit: dep, occurrence: $0) } }
            .sorted { ($0.occurrence.date, $0.deposit.name) < ($1.occurrence.date, $1.deposit.name) }
    }

    /// Occurrences inside an arbitrary range (for the calendar). Past payroll
    /// occurrences count as received.
    public func occurrences(of dep: Deposit, from first: Day, through last: Day) -> [(date: Day, received: Bool, awaiting: Bool)] {
        let t = today
        var occ: [(date: Day, received: Bool, awaiting: Bool)] = []
        if dep.type == .oneoff {
            if let d = dep.date.flatMap(Day.init(iso:)), d >= first, d <= last { occ.append((d, false, d < t)) }
            return occ
        }
        switch dep.cadence ?? .biweekly {
        case .weekly, .biweekly:
            let step = dep.cadence == .weekly ? 7 : 14
            guard var d = dep.anchor.flatMap(Day.init(iso:)), d <= last else { return occ }
            if d < first { d = d.adding(days: ((d.days(until: first) + step - 1) / step) * step) }
            while d <= last { occ.append((d, d < t, false)); d = d.adding(days: step) }
        case .monthly, .semimonthly:
            var m = Day.clamped(year: first.year, monthIndex: first.monthIndex, day: 1)
            while m <= last {
                let days = dep.cadence == .monthly ? [dep.day1 ?? 1] : [dep.day1 ?? 15, dep.day2 ?? 31]
                for day in days {
                    let d = Day.clamped(year: m.year, monthIndex: m.monthIndex, day: day)
                    if d >= first && d <= last { occ.append((d, d < t, false)) }
                }
                m = Day.clamped(year: m.year, monthIndex: m.monthIndex + 1, day: 1)
            }
            occ.sort { $0.date < $1.date }
        }
        return occ
    }

    // MARK: projections

    struct Event { var date: Day; var amount: Double; var rank: Int; var key: TimelineKey }

    /// Chronological cash events for one account. Outflows apply before
    /// same-day inflows (conservative); overdue items count as today.
    func events(for account: Account, within window: Int) -> [Event] {
        var evts: [Event] = []
        for x in upcomingBills(within: window) where x.bill.accountId == account.id {
            evts.append(Event(date: x.due.overdue ? today : x.due.date, amount: -x.bill.outflow, rank: 0, key: .bill(x.bill.id)))
        }
        for x in upcomingScheduled(within: window) where x.payment.accountId == account.id {
            evts.append(Event(date: x.days < 0 ? today : x.date, amount: -x.payment.amount, rank: 0, key: .scheduled(x.payment.id)))
        }
        for x in upcomingDeposits(within: window) where x.deposit.accountId == account.id {
            evts.append(Event(date: x.occurrence.awaiting ? today : x.occurrence.date, amount: x.deposit.amount, rank: 1,
                              key: .deposit(x.deposit.id, x.occurrence.date)))
        }
        // stable sort by date, then rank
        return evts.enumerated().sorted {
            ($0.element.date, $0.element.rank, $0.offset) < ($1.element.date, $1.element.rank, $1.offset)
        }.map(\.element)
    }

    public func projection(for account: Account, within window: Int = 30) -> Projection {
        var run = account.balance, minimum = account.balance, minDate = today, out = 0.0, inn = 0.0
        for e in events(for: account, within: window) {
            run = cents(run + e.amount)
            if e.amount < 0 { out -= e.amount } else { inn += e.amount }
            if run < minimum { minimum = run; minDate = e.date }
        }
        return Projection(outflow: out, inflow: inn, end: run, minimum: minimum, minimumDate: minDate)
    }

    /// Running balance before/after each timeline item, across all accounts.
    public func balanceSteps(within window: Int = 30) -> [TimelineKey: BalanceStep] {
        var map: [TimelineKey: BalanceStep] = [:]
        for a in state.accounts {
            var run = a.balance
            for e in events(for: a, within: window) {
                let before = run
                run = cents(run + e.amount)
                map[e.key] = BalanceStep(before: before, after: run)
            }
        }
        return map
    }

    /// Accounts projected to go negative within the window.
    public func shortAccounts(within window: Int = 30) -> [AccountProjection] {
        state.accounts.map { AccountProjection(account: $0, projection: projection(for: $0, within: window)) }
            .filter { $0.projection.dipsBelowZero }
    }

    /// Number shown on the Home tab badge.
    public func attentionCount() -> Int {
        let lead = state.settings.leadDays
        let manualSoon = upcomingBills(within: 30).filter { !$0.bill.autopay && ($0.due.overdue || $0.due.days <= lead) }.count
        return manualSoon + shortAccounts().count
    }

    // MARK: calendar

    public enum CalendarEvent: Hashable, Sendable {
        case bill(Bill, paid: Bool, overdue: Bool)
        case deposit(Deposit, received: Bool, awaiting: Bool)
        case scheduled(ScheduledPayment)

        public var marker: CalendarMarker {
            switch self {
            case .deposit: return .deposit
            case .scheduled: return .scheduled
            case let .bill(b, paid, overdue):
                if overdue { return .overdue }
                if paid || b.autopay { return .autopayOrPaid }
                return .manual
            }
        }
    }

    /// Every bill / deposit / scheduled-payment instance between two dates.
    public func calendarEvents(from first: Day, through last: Day) -> [Day: [CalendarEvent]] {
        var out: [Day: [CalendarEvent]] = [:]
        // each month the range touches
        var m = Day.clamped(year: first.year, monthIndex: first.monthIndex, day: 1)
        while m <= last {
            for b in state.bills {
                let d = Day.clamped(year: m.year, monthIndex: m.monthIndex, day: b.dueDay)
                guard d >= first, d <= last else { continue }
                let key = d.cycleKey
                if scheduled(forBill: b.id, cycle: key) != nil { continue } // shown as the scheduled payment
                let paid = (b.lastPaidCycle.map { $0 >= key } ?? false) || (b.autopay && d < today)
                let overdue = !paid && !b.autopay && d < today
                out[d, default: []].append(.bill(b, paid: paid, overdue: overdue))
            }
            m = Day.clamped(year: m.year, monthIndex: m.monthIndex + 1, day: 1)
        }
        for dep in state.deposits {
            for o in occurrences(of: dep, from: first, through: last) {
                out[o.date, default: []].append(.deposit(dep, received: o.received, awaiting: o.awaiting))
            }
        }
        for s in state.scheduled {
            if let d = s.day, d >= first, d <= last { out[d, default: []].append(.scheduled(s)) }
        }
        return out
    }
}

private func < (a: (Day, String), b: (Day, String)) -> Bool {
    a.0 != b.0 ? a.0 < b.0 : a.1.localizedStandardCompare(b.1) == .orderedAscending
}
