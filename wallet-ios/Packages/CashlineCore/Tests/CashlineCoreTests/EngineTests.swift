import XCTest
@testable import CashlineCore

final class DayTests: XCTestCase {
    func testClampAndRollover() {
        XCTAssertEqual(Day.clamped(year: 2026, monthIndex: 1, day: 31).iso, "2026-02-28")
        XCTAssertEqual(Day.clamped(year: 2028, monthIndex: 1, day: 31).iso, "2028-02-29")
        XCTAssertEqual(Day.clamped(year: 2026, monthIndex: -1, day: 15).iso, "2025-12-15")
        XCTAssertEqual(Day.clamped(year: 2026, monthIndex: 12, day: 3).iso, "2027-01-03")
        XCTAssertEqual(Day.clamped(year: 2026, monthIndex: -13, day: 3).iso, "2024-12-03")
    }

    func testArithmetic() {
        let d = Day(iso: "2026-11-07")!
        XCTAssertEqual(d.weekday, 6) // Saturday
        XCTAssertEqual(d.adding(days: 30).iso, "2026-12-07")
        XCTAssertEqual(d.adding(days: -400).iso, "2025-10-03")
        XCTAssertEqual(Day(iso: "1970-01-01")!.ordinal, 0)
        XCTAssertEqual(d.days(until: Day(iso: "2027-01-01")!), 55)
        XCTAssertNil(Day(iso: "2026-02-30"))
    }
}

final class EngineTests: XCTestCase {
    let today = Day(iso: "2026-11-07")!

    func state(_ bills: [Bill], accounts: [Account] = [Account(id: "a", name: "Checking", balance: 1000)]) -> AppState {
        var s = AppState(); s.accounts = accounts; s.bills = bills; return s
    }

    func testManualBillStaysOverdueUntilPaid() {
        let b = Bill(id: "b", name: "Trash", kind: .utility, amount: 40, dueDay: 5, accountId: "a", autopay: false, lastPaidCycle: "2026-10")
        let due = Engine(state: state([b]), today: today).nextDue(b)
        XCTAssertTrue(due.overdue)
        XCTAssertEqual(due.date.iso, "2026-11-05")
        XCTAssertEqual(due.days, -2)
    }

    func testAutopayRollsForward() {
        let b = Bill(id: "b", name: "Card", kind: .card, amount: 40, dueDay: 5, accountId: "a", autopay: true, lastPaidCycle: "2026-10")
        let due = Engine(state: state([b]), today: today).nextDue(b)
        XCTAssertFalse(due.overdue)
        XCTAssertEqual(due.date.iso, "2026-12-05")
    }

    func testNewBillIsNotBornOverdue() {
        XCTAssertEqual(Engine.initialPaidCycle(dueDay: 5, today: today), "2026-11")
        XCTAssertEqual(Engine.initialPaidCycle(dueDay: 20, today: today), "2026-10")
        var s = state([])
        s.upsertBill(Bill(name: "New", kind: .utility, amount: 10, dueDay: 3, accountId: "a", autopay: false), today: today)
        XCTAssertEqual(Engine(state: s, today: today).nextDue(s.bills[0]).date.iso, "2026-12-03")
    }

    func testShortMonthClamp() {
        let b = Bill(id: "b", name: "Rent", kind: .utility, amount: 1, dueDay: 31, accountId: "a", autopay: false, lastPaidCycle: "2026-10")
        XCTAssertEqual(Engine(state: state([b]), today: today).nextDue(b).date.iso, "2026-11-30")
    }

    func testDepositOccurrences() {
        var s = state([])
        let bi = Deposit(id: "d", name: "Pay", amount: 100, accountId: "a", type: .payroll, cadence: .biweekly, anchor: "2026-10-02")
        let semi = Deposit(id: "s", name: "Semi", amount: 100, accountId: "a", type: .payroll, cadence: .semimonthly, day1: 15, day2: 31)
        let one = Deposit(id: "o", name: "Refund", amount: 100, accountId: "a", type: .oneoff, date: "2026-11-01")
        s.deposits = [bi, semi, one]
        let e = Engine(state: s, today: today)
        XCTAssertEqual(e.occurrences(of: bi, within: 30).map(\.date.iso), ["2026-11-13", "2026-11-27"])
        XCTAssertEqual(e.occurrences(of: semi, within: 30).map(\.date.iso), ["2026-11-15", "2026-11-30"])
        let o = e.occurrences(of: one, within: 30)
        XCTAssertEqual(o.count, 1); XCTAssertTrue(o[0].awaiting)
    }

    func testProjectionOutflowsBeforeSameDayInflows() {
        var s = state([Bill(id: "b", name: "Card", kind: .card, amount: 1200, dueDay: 13, accountId: "a", autopay: true, lastPaidCycle: "2026-10")])
        s.deposits = [Deposit(id: "d", name: "Pay", amount: 500, accountId: "a", type: .payroll, cadence: .biweekly, anchor: "2026-11-13")]
        let p = Engine(state: s, today: today).projection(for: s.accounts[0])
        XCTAssertEqual(p.minimum, -200, accuracy: 0.001)
        XCTAssertEqual(p.minimumDate.iso, "2026-11-13")
        XCTAssertTrue(p.dipsBelowZero)
        XCTAssertEqual(Engine(state: s, today: today).attentionCount(), 1)
        let steps = Engine(state: s, today: today).balanceSteps()
        XCTAssertEqual(steps[.bill("b")], BalanceStep(before: 1000, after: -200))
    }

    func testFixedAutopayOutflow() {
        let b = Bill(id: "b", name: "Card", kind: .card, amount: 800, dueDay: 10, accountId: "a", autopay: true,
                     autopayMode: .fixed, autopayAmount: 250, lastPaidCycle: "2026-10")
        XCTAssertEqual(b.outflow, 250)
        let p = Engine(state: state([b]), today: today).projection(for: Account(id: "a", name: "x", balance: 1000))
        XCTAssertEqual(p.end, 750)
    }

    func testCalendarMarkers() {
        let b = Bill(id: "b", name: "Trash", kind: .utility, amount: 40, dueDay: 5, accountId: "a", autopay: false, lastPaidCycle: "2026-10")
        let ev = Engine(state: state([b]), today: today).calendarEvents(from: Day(iso: "2026-11-01")!, through: Day(iso: "2026-12-31")!)
        XCTAssertEqual(ev[Day(iso: "2026-11-05")!]?.first?.marker, .overdue)
        XCTAssertEqual(ev[Day(iso: "2026-12-05")!]?.first?.marker, .manual)
    }
}

final class ActionTests: XCTestCase {
    let today = Day(iso: "2026-11-07")!

    func base() -> AppState {
        var s = AppState()
        s.accounts = [Account(id: "a", name: "Checking", balance: 1000), Account(id: "c", name: "Savings", balance: 50)]
        s.bills = [Bill(id: "b", name: "Water", kind: .utility, amount: 80, dueDay: 12, accountId: "a", autopay: false, lastPaidCycle: "2026-10")]
        return s
    }

    func testPayNowDeductsAndRolls() {
        var s = base()
        XCTAssertEqual(s.recordPayment(billId: "b", amount: 80, date: today, accountId: "a", today: today), .paid(deducted: true))
        XCTAssertEqual(s.accounts[0].balance, 920)
        XCTAssertEqual(s.bills[0].lastPaidCycle, "2026-11")
        XCTAssertEqual(Engine(state: s, today: today).nextDue(s.bills[0]).date.iso, "2026-12-12")
        XCTAssertEqual(s.payments.count, 1)
    }

    func testScheduledPaymentHoldsThenPosts() {
        var s = base()
        let on = today.adding(days: 3)
        XCTAssertEqual(s.recordPayment(billId: "b", amount: 80, date: on, accountId: "a", today: today), .scheduled(on))
        XCTAssertEqual(s.accounts[0].balance, 1000)
        let e = Engine(state: s, today: today)
        XCTAssertEqual(e.nextDue(s.bills[0]).date.iso, "2026-12-12", "the held payment covers this cycle")
        XCTAssertEqual(e.projection(for: s.accounts[0]).end, 920, "the held payment still counts as money going out")

        XCTAssertTrue(s.processScheduled(today: today.adding(days: 2)).isEmpty)
        XCTAssertEqual(s.processScheduled(today: on).count, 1)
        XCTAssertEqual(s.accounts[0].balance, 920)
        XCTAssertEqual(s.bills[0].lastPaidCycle, "2026-11")
        XCTAssertTrue(s.scheduled.isEmpty)
    }

    func testCancelScheduledMakesBillDueAgain() {
        var s = base()
        s.recordPayment(billId: "b", amount: 80, date: today.adding(days: 3), accountId: "a", today: today)
        s.cancelScheduled(id: s.scheduled[0].id)
        XCTAssertEqual(Engine(state: s, today: today).nextDue(s.bills[0]).date.iso, "2026-11-12")
    }

    func testDeductSettingOff() {
        var s = base(); s.settings.deductOnPaid = false
        XCTAssertEqual(s.recordPayment(billId: "b", amount: 80, date: today, accountId: "a", today: today), .paid(deducted: false))
        XCTAssertEqual(s.accounts[0].balance, 1000)
    }

    func testPendingFoldsAfterDueDatePasses() {
        var s = base()
        s.bills[0].lastRolledCycle = "2026-10"
        s.postToNextStatement(billId: "b", amount: 20)
        XCTAssertTrue(s.processBillRolls(today: today).isEmpty, "Nov 12 hasn't passed yet")
        XCTAssertEqual(s.bills[0].pending, 20)
        let folded = s.processBillRolls(today: Day(iso: "2026-11-13")!)
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(s.bills[0].amount, 100)
        XCTAssertEqual(s.bills[0].pending, 0)
    }

    func testTransferAndReceive() {
        var s = base()
        XCTAssertTrue(s.transfer(from: "a", to: "c", amount: 100.004))
        XCTAssertEqual(s.accounts[0].balance, 900); XCTAssertEqual(s.accounts[1].balance, 150)
        XCTAssertFalse(s.transfer(from: "a", to: "a", amount: 5))
        s.deposits = [Deposit(id: "d", name: "Refund", amount: 25, accountId: "c", type: .oneoff, date: today.iso)]
        XCTAssertTrue(s.markReceived(depositId: "d"))
        XCTAssertEqual(s.accounts[1].balance, 175)
        XCTAssertTrue(s.deposits.isEmpty)
    }

    func testChangingDueDayDoesNotResurrectPaidCycle() {
        var s = base()
        var b = s.bills[0]; b.dueDay = 2 // Nov 2 already passed
        s.upsertBill(b, today: today)
        XCTAssertEqual(Engine(state: s, today: today).nextDue(s.bills[0]).date.iso, "2026-12-02")
    }

    func testSampleData() {
        let s = AppState.sample(today: today)
        XCTAssertEqual(s.accounts.count, 2)
        XCTAssertEqual(s.bills.count, 8)
        let e = Engine(state: s, today: today)
        XCTAssertTrue(e.upcomingBills(within: 30).contains { $0.due.overdue && $0.bill.name == "City Trash Service" })
        XCTAssertEqual(s.scheduled.count, 1)
    }
}

final class BackupTests: XCTestCase {
    func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "web-backup", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testImportsWebBackup() throws {
        let s = try Backup.decode(fixture())
        XCTAssertEqual(s.accounts.map(\.balance), [2350, 640.5])
        XCTAssertEqual(s.bills[0].autopayMode, .fixed)
        XCTAssertEqual(s.bills[0].iconID, "chase")
        XCTAssertEqual(s.bills[1].amount, 78.30, "string amounts from the web are accepted")
        XCTAssertEqual(s.bills[1].dueDay, 12)
        XCTAssertEqual(s.bills[1].iconID, "drop", "icon suggested from the name")
        XCTAssertEqual(s.deposits[0].cadence, .biweekly)
        XCTAssertTrue(s.settings.notificationsEnabled)
        XCTAssertEqual(s.notified.count, 1)
    }

    func testRoundTripKeepsWebKeys() throws {
        let s = try Backup.decode(fixture())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Backup.encode(s)) as? [String: Any])
        let settings = try XCTUnwrap(obj["settings"] as? [String: Any])
        XCTAssertEqual(settings["browserNotif"] as? Bool, true)
        XCTAssertNotNil(settings["lastDriveBackup"])
        XCTAssertEqual(try Backup.decode(Backup.encode(s)), s)
    }

    func testRejectsNonBackup() {
        XCTAssertThrowsError(try Backup.decode(Data(#"{"hello": 1}"#.utf8)))
    }
}

final class ReminderTests: XCTestCase {
    func testPlansLeadDueAndLate() {
        let today = Day(iso: "2026-11-07")!
        var s = AppState()
        s.accounts = [Account(id: "a", name: "Checking", balance: 100)]
        s.bills = [Bill(id: "b", name: "Water", kind: .utility, amount: 80, dueDay: 20, accountId: "a", autopay: false, lastPaidCycle: "2026-10"),
                   Bill(id: "x", name: "Auto", kind: .card, amount: 80, dueDay: 20, accountId: "a", autopay: true, lastPaidCycle: "2026-10")]
        let r = ReminderPlanner.plan(s, today: today, currentHour: 8)
        XCTAssertEqual(r.map(\.id).filter { $0.contains("|b|2026-11") }, ["lead|b|2026-11", "due|b|2026-11", "late|b|2026-11"])
        XCTAssertEqual(r.first?.day.iso, "2026-11-15")
        XCTAssertFalse(r.contains { $0.id.contains("|x|") }, "autopay bills get no reminders")
    }

    func testOverdueFiresNextHour() {
        let today = Day(iso: "2026-11-07")!
        var s = AppState()
        s.bills = [Bill(id: "b", name: "Trash", kind: .utility, amount: 40, dueDay: 5, accountId: nil, autopay: false, lastPaidCycle: "2026-10")]
        let r = ReminderPlanner.plan(s, today: today, currentHour: 14)
        XCTAssertEqual(r.first?.id, "overdue|b|2026-11")
        XCTAssertEqual(r.first?.hour, 15)
    }
}
