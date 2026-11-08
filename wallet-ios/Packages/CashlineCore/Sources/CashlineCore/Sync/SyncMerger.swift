import Foundation

/// What a sync changed, for the confirmation message.
public struct SyncReport: Equatable, Sendable {
    public var accountsAdded = 0
    public var accountsUpdated = 0
    public var billsAdded = 0
    public var billsUpdated = 0
    public var billsMarkedPaid = 0
    public var depositsAdded = 0
    public var depositsUpdated = 0
    public var depositsRemoved = 0

    public init() {}

    public var summary: String {
        var parts: [String] = []
        if accountsAdded + billsAdded + depositsAdded > 0 {
            parts.append("\(accountsAdded + billsAdded + depositsAdded) new")
        }
        if accountsUpdated + billsUpdated + depositsUpdated > 0 {
            parts.append("\(accountsUpdated + billsUpdated + depositsUpdated) updated")
        }
        if billsMarkedPaid > 0 { parts.append("\(billsMarkedPaid) bill\(billsMarkedPaid == 1 ? "" : "s") marked paid") }
        return parts.isEmpty ? "Everything is up to date" : "Synced — " + parts.joined(separator: ", ")
    }
}

/// Folds bank data into the local state.
///
/// Rules:
/// - Bank data owns balances, statement amounts and due dates of linked
///   records. The user's own choices — names, icons, autopay, which checking
///   account pays a card — are kept.
/// - Depository accounts → Cashline accounts (balance = available, else current).
/// - Credit accounts + liabilities → credit-card bills.
/// - Active recurring inflows (payroll) → recurring deposits.
/// - Manual records are never touched.
public enum SyncMerger {
    public static func merge(_ snap: SyncSnapshot, into state: inout AppState, today: Day) -> SyncReport {
        var report = SyncReport()
        state.linkedItems = snap.items
        let institutions = Dictionary(snap.items.map { ($0.id, $0.institutionName) }, uniquingKeysWith: { a, _ in a })
        func link(_ itemId: String, _ externalId: String, mask: String?) -> ExternalLink {
            ExternalLink(provider: "plaid", itemId: itemId, externalId: externalId,
                         institution: institutions[itemId] ?? nil, mask: mask, lastSynced: snap.syncedAt)
        }

        // 1. checking / savings accounts
        var localAccountFor: [String: String] = [:] // external account id → local account id
        for ext in snap.accounts where ext.type == .depository {
            let balance = ext.availableBalance ?? ext.currentBalance
            var accountLink = link(ext.itemId, ext.id, mask: ext.mask)
            accountLink.balanceAsOf = ext.balanceUpdatedAt
            accountLink.balanceIsLive = ext.isLiveBalance
            if let i = state.accounts.firstIndex(where: { $0.link?.externalId == ext.id }) {
                if let balance { state.accounts[i].balance = cents(balance) }
                state.accounts[i].link = accountLink
                localAccountFor[ext.id] = state.accounts[i].id
                report.accountsUpdated += 1
            } else {
                let name = ext.mask.map { "\(ext.name) …\($0)" } ?? ext.name
                let a = Account(name: name, balance: cents(balance ?? 0), link: accountLink)
                state.accounts.append(a)
                localAccountFor[ext.id] = a.id
                report.accountsAdded += 1
            }
        }

        // 2. credit cards
        let liabilities = Dictionary(snap.creditLiabilities.map { ($0.accountId, $0) }, uniquingKeysWith: { a, _ in a })
        for ext in snap.accounts where ext.type == .credit {
            let liab = liabilities[ext.id]
            let statement = liab?.lastStatementBalance ?? ext.currentBalance
            let dueDay = liab?.nextPaymentDueDate?.day

            let i: Int
            if let found = state.bills.firstIndex(where: { $0.link?.externalId == ext.id }) {
                i = found
                if let statement { state.bills[i].amount = max(0, cents(statement)) }
                if let dueDay, dueDay != state.bills[i].dueDay {
                    var b = state.bills[i]; b.dueDay = dueDay
                    state.upsertBill(b, today: today) // re-anchors cycles like a manual edit
                }
                state.bills[i].link = link(ext.itemId, ext.id, mask: ext.mask)
                report.billsUpdated += 1
            } else {
                // pay from a checking account at the same bank, else the first one
                let payFrom = snap.accounts.first { $0.itemId == ext.itemId && $0.type == .depository }
                    .flatMap { localAccountFor[$0.id] } ?? state.accounts.first?.id
                let name = ext.mask.map { "\(ext.name) …\($0)" } ?? ext.name
                let b = Bill(name: name, kind: .card, amount: max(0, cents(statement ?? 0)), dueDay: dueDay ?? 1,
                             accountId: payFrom, autopay: false, link: link(ext.itemId, ext.id, mask: ext.mask))
                state.upsertBill(b, today: today)
                i = state.bills.count - 1
                report.billsAdded += 1
            }

            if let liab, applyPaymentStatus(liab, billIndex: i, state: &state, today: today) {
                report.billsMarkedPaid += 1
            }
        }

        // 3. payroll and other recurring income
        for stream in snap.recurringInflows {
            let existing = state.deposits.firstIndex { $0.link?.externalId == stream.id }
            guard stream.isActive, let cadence = stream.frequency.cadence,
                  let acct = localAccountFor[stream.accountId] else {
                if let existing { state.deposits.remove(at: existing); report.depositsRemoved += 1 }
                continue
            }
            let itemId = snap.accounts.first { $0.id == stream.accountId }?.itemId ?? ""
            var d = existing.map { state.deposits[$0] }
                ?? Deposit(name: stream.merchantName ?? stream.description, amount: 0, accountId: acct, type: .payroll)
            d.amount = cents(abs(stream.averageAmount))
            d.type = .payroll
            d.cadence = cadence
            d.accountId = acct
            d.date = nil; d.anchor = nil; d.day1 = nil; d.day2 = nil
            let next = stream.predictedNextDate ?? stream.lastDate ?? today
            switch cadence {
            case .weekly, .biweekly: d.anchor = next.iso
            case .monthly: d.day1 = next.day >= 28 ? 31 : next.day
            case .semimonthly:
                let days = [stream.lastDate?.day ?? 15, next.day].map { $0 >= 28 ? 31 : $0 }
                d.day1 = days.min(); d.day2 = days.max()
                if d.day1 == d.day2 { d.day1 = d.day2 == 31 ? 15 : d.day1; d.day2 = 31 }
            }
            d.link = link(itemId, stream.id, mask: nil)
            if let existing { state.deposits[existing] = d; report.depositsUpdated += 1 }
            else { state.deposits.append(d); report.depositsAdded += 1 }
        }

        // 4. a held in-app payment for a cycle the bank now shows as paid
        //    already happened — drop it so it isn't debited twice
        let bills = state.bills
        state.scheduled.removeAll { s in
            guard let b = bills.first(where: { $0.id == s.billId }), b.link != nil, let paid = b.lastPaidCycle else { return false }
            return paid >= s.cycle
        }
        return report
    }

    /// Aligns a linked card's paid cycle with the bank's statement data.
    /// Returns true when the current cycle was newly marked paid.
    static func applyPaymentStatus(_ liab: ExternalCreditLiability, billIndex i: Int, state: inout AppState, today: Day) -> Bool {
        let dueDay = state.bills[i].dueDay
        // The bank's next due date implies every earlier cycle is settled,
        // unless it reports the account overdue.
        if let npd = liab.nextPaymentDueDate, liab.isOverdue != true {
            let base = Day.clamped(year: npd.year, monthIndex: npd.monthIndex - 1, day: dueDay).cycleKey
            if (state.bills[i].lastPaidCycle ?? "") < base { state.bills[i].lastPaidCycle = base }
        }
        // A payment made after the current statement was issued (or after the
        // previous due date) covers the current cycle, if it meets the minimum.
        guard let paidOn = liab.lastPaymentDate, paidOn <= today else { return false }
        // judge against the bill's own cycle, ignoring any held in-app payment
        var bare = state
        bare.scheduled.removeAll { $0.billId == state.bills[i].id }
        let next = Engine(state: bare, today: today).nextDue(state.bills[i])
        if let npd = liab.nextPaymentDueDate, npd.cycleKey != next.key { return false }
        let prevDue = Day.clamped(year: next.date.year, monthIndex: next.date.monthIndex - 1, day: dueDay)
        let windowStart = liab.lastStatementIssueDate ?? prevDue.adding(days: 1)
        guard paidOn >= windowStart else { return false }
        if let min = liab.minimumPaymentAmount, let amt = liab.lastPaymentAmount, amt + 0.005 < min { return false }
        state.bills[i].lastPaidCycle = next.key
        return true
    }
}
