import XCTest
@testable import CashlineCore

final class SyncTests: XCTestCase {
    let today = Day(iso: "2026-11-07")!

    func snapshot(lastPayment: Day? = nil, nextDue: Day? = nil, stream: Bool = true) -> SyncSnapshot {
        SyncSnapshot(
            items: [LinkedItem(id: "item1", institutionName: "First Platypus Bank")],
            accounts: [
                ExternalAccount(id: "chk", itemId: "item1", name: "Plaid Checking", mask: "0000", type: .depository,
                                currentBalance: 110, availableBalance: 100),
                ExternalAccount(id: "cc", itemId: "item1", name: "Plaid Credit Card", mask: "3333", type: .credit, currentBalance: 410),
            ],
            creditLiabilities: [ExternalCreditLiability(
                accountId: "cc", lastStatementBalance: 410.5, lastStatementIssueDate: Day(iso: "2026-10-25"),
                minimumPaymentAmount: 25, nextPaymentDueDate: nextDue ?? Day(iso: "2026-11-20"),
                lastPaymentAmount: 410.5, lastPaymentDate: lastPayment, isOverdue: false)],
            recurringInflows: stream ? [ExternalRecurringInflow(
                id: "s1", accountId: "chk", description: "ACME PAYROLL", merchantName: "Acme", averageAmount: -2000,
                frequency: .biweekly, lastDate: Day(iso: "2026-10-30"), predictedNextDate: Day(iso: "2026-11-13"))] : [])
    }

    func testFirstSyncCreatesRecords() {
        var s = AppState()
        let r = SyncMerger.merge(snapshot(), into: &s, today: today)
        XCTAssertEqual(r.accountsAdded, 1); XCTAssertEqual(r.billsAdded, 1); XCTAssertEqual(r.depositsAdded, 1)
        XCTAssertEqual(s.accounts[0].name, "Plaid Checking …0000")
        XCTAssertEqual(s.accounts[0].balance, 100, "available balance wins")
        let bill = s.bills[0]
        XCTAssertEqual(bill.amount, 410.5); XCTAssertEqual(bill.dueDay, 20); XCTAssertEqual(bill.accountId, s.accounts[0].id)
        XCTAssertEqual(Engine(state: s, today: today).nextDue(bill).date.iso, "2026-11-20")
        XCTAssertEqual(s.deposits[0].amount, 2000)
        XCTAssertEqual(s.deposits[0].anchor, "2026-11-13")
        XCTAssertEqual(s.linkedItems.count, 1)
    }

    func testResyncKeepsUserChoicesAndUpdatesBankFields() {
        var s = AppState()
        _ = SyncMerger.merge(snapshot(), into: &s, today: today)
        s.bills[0].name = "My card"; s.bills[0].autopay = true; s.bills[0].icon = "amex"
        s.accounts.append(Account(id: "manual", name: "Cash jar", balance: 20))
        var snap = snapshot()
        snap.accounts[0].availableBalance = 555
        snap.creditLiabilities[0].lastStatementBalance = 99
        let r = SyncMerger.merge(snap, into: &s, today: today)
        XCTAssertEqual(r.accountsAdded + r.billsAdded + r.depositsAdded, 0)
        XCTAssertEqual(s.accounts.count, 2)
        XCTAssertEqual(s.accounts[0].balance, 555)
        XCTAssertEqual(s.accounts[1].balance, 20, "manual accounts untouched")
        XCTAssertEqual(s.bills[0].name, "My card"); XCTAssertTrue(s.bills[0].autopay); XCTAssertEqual(s.bills[0].icon, "amex")
        XCTAssertEqual(s.bills[0].amount, 99)
    }

    func testPaymentAfterStatementMarksCyclePaid() {
        var s = AppState()
        _ = SyncMerger.merge(snapshot(), into: &s, today: today)
        s.recordPayment(billId: s.bills[0].id, amount: 410.5, date: today.adding(days: 3), accountId: s.accounts[0].id, today: today)
        XCTAssertEqual(s.scheduled.count, 1)
        let r = SyncMerger.merge(snapshot(lastPayment: Day(iso: "2026-11-02")), into: &s, today: today)
        XCTAssertEqual(r.billsMarkedPaid, 1)
        XCTAssertEqual(s.bills[0].lastPaidCycle, "2026-11")
        XCTAssertTrue(s.scheduled.isEmpty, "held payment the bank already shows is dropped")
    }

    func testPaymentBeforeStatementDoesNotCount() {
        var s = AppState()
        let r = SyncMerger.merge(snapshot(lastPayment: Day(iso: "2026-10-20")), into: &s, today: today)
        XCTAssertEqual(r.billsMarkedPaid, 0)
        XCTAssertFalse(Engine(state: s, today: today).nextDue(s.bills[0]).overdue)
    }

    func testInactiveStreamRemovesDeposit() {
        var s = AppState()
        _ = SyncMerger.merge(snapshot(), into: &s, today: today)
        var snap = snapshot(); snap.recurringInflows[0].isActive = false
        let r = SyncMerger.merge(snap, into: &s, today: today)
        XCTAssertEqual(r.depositsRemoved, 1)
        XCTAssertTrue(s.deposits.isEmpty)
    }

    func testDecodesBackendJSON() throws {
        let json = #"""
        {"items":[{"id":"item1","provider":"plaid","institution_name":"Chase","status":"ok","last_synced_at":"2026-11-07T10:00:00Z"}],
         "accounts":[{"id":"acc1","item_id":"item1","name":"Checking","mask":"1234","type":"depository","subtype":"checking",
                      "current_balance":10.5,"available_balance":9.5,"iso_currency_code":"USD"},
                     {"id":"acc2","item_id":"item1","name":"Brokerage","type":"brokerage"}],
         "credit_liabilities":[{"account_id":"acc3","last_statement_balance":12,"next_payment_due_date":"2026-11-20"}],
         "recurring_inflows":[{"id":"s","account_id":"acc1","description":"PAY","average_amount":100,
                               "frequency":"SEMI_MONTHLY","is_active":true}],
         "synced_at":"2026-11-07T10:00:00.123Z"}
        """#
        let snap = try JSONDecoder.cashlineAPI.decode(SyncSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.items[0].institutionName, "Chase")
        XCTAssertEqual(snap.accounts[1].type, .other)
        XCTAssertEqual(snap.creditLiabilities[0].nextPaymentDueDate?.iso, "2026-11-20")
        XCTAssertEqual(snap.recurringInflows[0].frequency, .semiMonthly)
    }

    func testMockBackendFlow() async throws {
        let t = today
        let mock = MockCashlineBackend(today: { t })
        _ = try await mock.createLinkToken(updateItemId: nil)
        _ = try await mock.exchangePublicToken("public-sandbox", institutionName: "Demo Bank")
        var s = AppState()
        let r = SyncMerger.merge(try await mock.fetchSnapshot(), into: &s, today: today)
        XCTAssertEqual(r.accountsAdded, 1); XCTAssertEqual(r.billsAdded, 1); XCTAssertEqual(r.depositsAdded, 1)
    }
}
