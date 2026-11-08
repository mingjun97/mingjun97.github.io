import Foundation

/// A fake backend with one demo bank, so the whole link → sync → merge flow
/// can be built and tried before a real server (or Plaid keys) exist.
public actor MockCashlineBackend: CashlineBackend {
    private var linked: [LinkedItem] = []
    private let today: @Sendable () -> Day

    public init(today: @escaping @Sendable () -> Day = { Day.today() }) { self.today = today }

    public func createLinkToken(updateItemId: String?) async throws -> String { "link-sandbox-demo" }

    public func exchangePublicToken(_ publicToken: String, institutionName: String?) async throws -> LinkedItem {
        let item = LinkedItem(id: "item-demo-\(linked.count + 1)", institutionName: institutionName ?? "Demo Bank", lastSyncedAt: Date())
        linked.append(item)
        return item
    }

    public func fetchSnapshot(liveBalances: Bool) async throws -> SyncSnapshot {
        let t = today()
        var snap = SyncSnapshot(items: linked, syncedAt: Date())
        for item in linked {
            let p = item.id
            let bank = item.institutionName ?? "Demo Bank"
            snap.accounts += [
                ExternalAccount(id: "\(p)-chk", itemId: p, name: "\(bank) Checking", mask: "0042", type: .depository,
                                subtype: "checking", currentBalance: 3120.55, availableBalance: 3080.55,
                                balanceSource: liveBalances ? "realtime" : "cached",
                                balanceUpdatedAt: liveBalances ? Date() : Date().addingTimeInterval(-3 * 3600)),
                ExternalAccount(id: "\(p)-cc", itemId: p, name: "\(bank) Rewards Card", mask: "9911", type: .credit,
                                subtype: "credit card", currentBalance: 684.12),
            ]
            snap.creditLiabilities.append(ExternalCreditLiability(
                accountId: "\(p)-cc", lastStatementBalance: 512.30, lastStatementIssueDate: t.adding(days: -12),
                minimumPaymentAmount: 35, nextPaymentDueDate: t.adding(days: 11),
                lastPaymentAmount: 401.77, lastPaymentDate: t.adding(days: -20), isOverdue: false))
            snap.recurringInflows.append(ExternalRecurringInflow(
                id: "\(p)-payroll", accountId: "\(p)-chk", description: "ACME CORP PAYROLL", merchantName: "Acme Corp",
                averageAmount: 2150, lastAmount: 2150, frequency: .biweekly,
                lastDate: t.adding(days: -9), predictedNextDate: t.adding(days: 5), isActive: true))
        }
        return snap
    }

    public func removeItem(id: String) async throws { linked.removeAll { $0.id == id } }
}
