import Foundation

// State changes. Each one mirrors a web-app action and returns a short
// message for the confirmation toast. Undo is handled by the caller taking a
// snapshot of the state before calling.

public enum PaymentOutcome: Equatable, Sendable {
    case paid(deducted: Bool)
    case scheduled(Day)
}

extension AppState {
    private func engine(_ today: Day) -> Engine { Engine(state: self, today: today) }

    private mutating func adjustBalance(_ accountId: String?, by delta: Double) -> Bool {
        guard settings.deductOnPaid, let i = accounts.firstIndex(where: { $0.id == accountId }) else { return false }
        accounts[i].balance = cents(accounts[i].balance + delta)
        return true
    }

    private mutating func appendPayment(_ p: Payment) {
        payments.append(p)
        if payments.count > 200 { payments.removeFirst(payments.count - 200) }
    }

    // MARK: time passing

    /// Folds posted next-statement charges into the amount due once a due date
    /// passes. Returns (bill name, amount) for each fold.
    @discardableResult
    public mutating func processBillRolls(today: Day) -> [(name: String, amount: Double)] {
        var folded: [(String, Double)] = []
        let e = engine(today)
        for i in bills.indices {
            guard let k = e.lastPassedDueKey(bills[i]) else { continue }
            if let rolled = bills[i].lastRolledCycle, rolled >= k { continue }
            if bills[i].pending > 0 {
                bills[i].amount = cents(bills[i].amount + bills[i].pending)
                folded.append((bills[i].name, bills[i].pending))
                bills[i].pending = 0
            }
            bills[i].lastRolledCycle = k
        }
        return folded
    }

    /// Posts every scheduled payment whose date has arrived: debits the
    /// account and marks the bill's cycle paid.
    @discardableResult
    public mutating func processScheduled(today: Day) -> [ScheduledPayment] {
        let due = scheduled.filter { ($0.day ?? today) <= today }
        for s in due {
            if let i = bills.firstIndex(where: { $0.id == s.billId }), (bills[i].lastPaidCycle ?? "") < s.cycle {
                bills[i].lastPaidCycle = s.cycle
            }
            _ = adjustBalance(s.accountId, by: -s.amount)
            appendPayment(Payment(billId: s.billId, name: s.name, amount: s.amount, date: s.date,
                                  accountId: s.accountId, cycle: s.cycle, wasScheduled: true))
        }
        let ids = Set(due.map(\.id))
        scheduled.removeAll { ids.contains($0.id) }
        return due
    }

    // MARK: bills

    /// Records a payment for the bill's next due cycle. A future date holds the
    /// payment (scheduled) instead of debiting now.
    @discardableResult
    public mutating func recordPayment(billId: String, amount: Double, date: Day, accountId: String?, today: Day) -> PaymentOutcome? {
        guard let i = bills.firstIndex(where: { $0.id == billId }) else { return nil }
        let due = engine(today).nextDue(bills[i])
        let amount = max(0, cents(amount))
        let acct = account(accountId)?.id
        if date > today {
            scheduled.append(ScheduledPayment(billId: billId, name: bills[i].name, amount: amount,
                                              date: date.iso, accountId: acct, cycle: due.key))
            return .scheduled(date)
        }
        bills[i].lastPaidCycle = due.key
        let deducted = adjustBalance(acct, by: -amount)
        appendPayment(Payment(billId: billId, name: bills[i].name, amount: amount, date: date.iso, accountId: acct, cycle: due.key))
        return .paid(deducted: deducted)
    }

    /// Cancels a held payment; the bill's cycle becomes due again.
    public mutating func cancelScheduled(id: String) {
        scheduled.removeAll { $0.id == id }
    }

    /// Posts a held payment now instead of waiting for its date.
    public mutating func payScheduledNow(id: String, today: Day) {
        guard let s = scheduled.first(where: { $0.id == id }) else { return }
        if let i = bills.firstIndex(where: { $0.id == s.billId }), (bills[i].lastPaidCycle ?? "") < s.cycle {
            bills[i].lastPaidCycle = s.cycle
        }
        _ = adjustBalance(s.accountId, by: -s.amount)
        scheduled.removeAll { $0.id == id }
        appendPayment(Payment(billId: s.billId, name: s.name, amount: s.amount, date: today.iso, accountId: s.accountId, cycle: s.cycle))
    }

    /// Sets the current statement's amount due.
    public mutating func setAmountDue(billId: String, amount: Double) {
        guard let i = bills.firstIndex(where: { $0.id == billId }) else { return }
        bills[i].amount = max(0, cents(amount))
    }

    /// Posts a charge (or a negative correction) to the next statement.
    public mutating func postToNextStatement(billId: String, amount: Double) {
        guard let i = bills.firstIndex(where: { $0.id == billId }) else { return }
        bills[i].pending = max(0, cents(bills[i].pending + amount))
    }

    /// Adds or replaces a bill. New bills start with the last passed cycle
    /// marked paid, so they aren't born overdue.
    public mutating func upsertBill(_ bill: Bill, today: Day) {
        if let i = bills.firstIndex(where: { $0.id == bill.id }) {
            var b = bill
            if b.dueDay != bills[i].dueDay {
                // moving the due day must not make an already-passed cycle due again,
                // nor fold pending charges early
                let base = Engine.initialPaidCycle(dueDay: b.dueDay, today: today)
                if (b.lastPaidCycle ?? "") < base { b.lastPaidCycle = base }
                b.lastRolledCycle = Engine(state: self, today: today).lastPassedDueKey(b)
            }
            bills[i] = b
        } else {
            var b = bill
            if b.lastPaidCycle == nil { b.lastPaidCycle = Engine.initialPaidCycle(dueDay: b.dueDay, today: today) }
            if b.lastRolledCycle == nil { b.lastRolledCycle = Engine(state: self, today: today).lastPassedDueKey(b) }
            bills.append(b)
        }
    }

    public mutating func deleteBill(id: String) {
        bills.removeAll { $0.id == id }
        scheduled.removeAll { $0.billId == id }
    }

    // MARK: deposits

    public mutating func upsertDeposit(_ dep: Deposit) {
        if let i = deposits.firstIndex(where: { $0.id == dep.id }) { deposits[i] = dep } else { deposits.append(dep) }
    }

    public mutating func deleteDeposit(id: String) { deposits.removeAll { $0.id == id } }

    /// Marks a one-time deposit as arrived: adds it to the balance and removes it.
    @discardableResult
    public mutating func markReceived(depositId: String) -> Bool {
        guard let dep = deposits.first(where: { $0.id == depositId }), dep.type == .oneoff else { return false }
        let added = adjustBalance(dep.accountId, by: dep.amount)
        deposits.removeAll { $0.id == depositId }
        return added
    }

    // MARK: accounts

    public mutating func upsertAccount(_ a: Account) {
        if let i = accounts.firstIndex(where: { $0.id == a.id }) { accounts[i] = a } else { accounts.append(a) }
    }

    /// Deletes an account. Linked bills keep their data and show "No account".
    public mutating func deleteAccount(id: String) { accounts.removeAll { $0.id == id } }

    public mutating func postToAccount(id: String, amount: Double) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].balance = cents(accounts[i].balance + amount)
    }

    @discardableResult
    public mutating func transfer(from: String, to: String, amount: Double) -> Bool {
        let amt = cents(amount)
        guard from != to, amt > 0,
              let f = accounts.firstIndex(where: { $0.id == from }),
              let t = accounts.firstIndex(where: { $0.id == to }) else { return false }
        accounts[f].balance = cents(accounts[f].balance - amt)
        accounts[t].balance = cents(accounts[t].balance + amt)
        return true
    }

    public mutating func moveAccounts(fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.map { accounts[$0] }
        var rest = accounts.enumerated().filter { !fromOffsets.contains($0.offset) }.map(\.element)
        let insertAt = toOffset - fromOffsets.filter { $0 < toOffset }.count
        rest.insert(contentsOf: moving, at: min(max(0, insertAt), rest.count))
        accounts = rest
    }
}
