import Foundation

/// A local notification to schedule. The app turns these into
/// `UNNotificationRequest`s; planning lives here so it can be tested.
public struct Reminder: Hashable, Sendable {
    public var id: String
    public var day: Day
    public var hour: Int
    public var title: String
    public var body: String
}

public enum ReminderPlanner {
    /// iOS keeps at most 64 pending local notifications per app.
    public static let limit = 60

    /// Reminders for the next ~2 months. Unlike the web app (which could only
    /// notify while open), these fire on schedule even when the app is closed.
    ///
    /// - Parameters:
    ///   - hour: hour of day reminders fire.
    ///   - currentHour: the hour right now; anything for today at or before it
    ///     moves to the next hour so it still fires.
    public static func plan(_ state: AppState, today: Day, hour: Int = 9, currentHour: Int) -> [Reminder] {
        let e = Engine(state: state, today: today)
        let lead = state.settings.leadDays
        let money = { (x: Double) in x.formatted(.currency(code: "USD")) }
        var out: [Reminder] = []
        var used = Set<String>() // bill+day, so one bill never gets two reminders on one day

        func add(_ id: String, _ owner: String, _ day: Day, _ title: String, _ body: String) {
            guard day >= today, used.insert(owner + "@" + day.iso).inserted else { return }
            let h = day == today && hour <= currentHour ? currentHour + 1 : hour
            guard h <= 23 else { return }
            out.append(Reminder(id: id, day: day, hour: h, title: title, body: body))
        }

        for x in e.upcomingBills(within: 62) where !x.bill.autopay {
            let b = x.bill, due = x.due
            let body = "\(money(b.amount)) from \(state.accountName(b.accountId)) — not on autopay."
            if due.overdue {
                add("overdue|\(b.id)|\(due.key)", b.id, today, "Overdue: \(b.name)", body)
                continue
            }
            if lead > 0 {
                let on = max(due.date.adding(days: -lead), today)
                let n = on.days(until: due.date)
                if n > 0 {
                    add("lead|\(b.id)|\(due.key)", b.id, on,
                        n == 1 ? "Bill due tomorrow: \(b.name)" : "Bill due in \(n) days: \(b.name)", body)
                }
            }
            add("due|\(b.id)|\(due.key)", b.id, due.date, "Bill due today: \(b.name)", body)
            add("late|\(b.id)|\(due.key)", b.id, due.date.adding(days: 1), "Overdue: \(b.name)", body)
        }
        for x in e.upcomingScheduled(within: 62) {
            let s = x.payment
            add("posting|\(s.id)", s.id, x.date, "Scheduled payment today: \(s.name)",
                "\(money(s.amount)) from \(state.accountName(s.accountId)). Open Cashline to post it.")
        }
        return Array(out.sorted { ($0.day, $0.hour, $0.id) < ($1.day, $1.hour, $1.id) }.prefix(limit))
    }
}
