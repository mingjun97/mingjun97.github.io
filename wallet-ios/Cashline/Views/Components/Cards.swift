import SwiftUI
import CashlineCore

/// "Account: $X at pay → $Y after"
struct ProjectionLine: View {
    let step: BalanceStep?

    var body: some View {
        if let step {
            HStack(spacing: 3) {
                Text("Account:")
                Text(step.before.usd).monospacedDigit().fontWeight(.semibold)
                Text("at pay →")
                Text(step.after.usd).monospacedDigit().fontWeight(.semibold)
                    .foregroundStyle(step.after < -0.005 ? Theme.danger : Theme.muted)
                Text("after")
            }
            .font(.caption)
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

struct BillCard: View {
    @Environment(AppStore.self) private var store
    let item: UpcomingBill
    var step: BalanceStep?
    var showDate = false

    var body: some View {
        let b = item.bill, due = item.due
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BillIconView(id: b.iconID)
                Text(b.name).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                Text(b.amount.usd).font(.body.monospacedDigit().weight(.semibold))
            }
            ProjectionLine(step: step).padding(.top, 3)
            FlowLayout(spacing: 6) {
                if due.overdue { Chip("Overdue", .overdue) }
                if b.autopay {
                    Chip("⚡ Autopay" + (b.autopayMode == .fixed ? " · \(b.autopayDraft.usd) fixed" : ""), .autopay)
                } else {
                    Chip("Manual pay", .manual)
                }
                if store.state.scheduled.contains(where: { $0.billId == b.id }) { Chip("⏱ Payment scheduled", .scheduled) }
                if b.pending > 0 { Chip("+\(b.pending.usd) next stmt", .pending) }
                if let link = b.link { Chip("Synced · \(link.institution ?? "bank")", .linked) }
                Chip(store.state.accountName(b.accountId), .account)
                if showDate { Chip("\(DayText.short(due.date)) · \(DayText.relative(due.days))", .account) }
            }
            .padding(.top, 7)
            HStack(spacing: 8) {
                Button("Balance") { store.sheet = .balance(b.id) }.buttonStyle(.cardGhost)
                Button("Edit") { store.sheet = .editBill(b.id) }.buttonStyle(.cardSubtle)
                Spacer()
                if !b.autopay {
                    Button("Mark paid") { store.sheet = .pay(b.id) }.buttonStyle(.cardPrimary)
                }
            }
            .padding(.top, 10)
        }
        .card()
        .contextMenu {
            if !b.autopay { Button("Mark paid", systemImage: "checkmark.circle") { store.sheet = .pay(b.id) } }
            Button("Update balance", systemImage: "dollarsign.circle") { store.sheet = .balance(b.id) }
            Button("Edit", systemImage: "pencil") { store.sheet = .editBill(b.id) }
        }
    }
}

struct ScheduledCard: View {
    @Environment(AppStore.self) private var store
    let item: UpcomingScheduled
    var step: BalanceStep?
    var showDate = false

    var body: some View {
        let s = item.payment
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                BillIconView(id: store.state.bill(s.billId)?.iconID ?? "bill")
                Text(s.name).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                Text(s.amount.usd).font(.body.monospacedDigit().weight(.semibold))
            }
            ProjectionLine(step: step).padding(.top, 3)
            FlowLayout(spacing: 6) {
                Chip("⏱ Scheduled", .scheduled)
                Chip(store.state.accountName(s.accountId), .account)
                if showDate { Chip(DayText.short(item.date), .account) }
            }
            .padding(.top, 7)
            HStack(spacing: 8) {
                Button("Pay now") {
                    store.update("\(s.name) paid — \(s.amount.usd)") { $0.payScheduledNow(id: s.id, today: store.today) }
                }
                .buttonStyle(.cardPrimary)
                Button("Cancel") {
                    store.update("Scheduled payment for \(s.name) canceled") { $0.cancelScheduled(id: s.id) }
                }
                .buttonStyle(.cardSubtle)
            }
            .padding(.top, 10)
        }
        .card(edge: Theme.accent, dashed: true)
    }
}

struct DepositCard: View {
    @Environment(AppStore.self) private var store
    let deposit: Deposit
    let occurrence: DepositOccurrence?
    var showDate = false

    var body: some View {
        let dep = deposit
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                DepositIconView()
                Text(dep.name).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                Text("+" + dep.amount.usd).font(.body.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.good)
            }
            FlowLayout(spacing: 6) {
                if occurrence?.awaiting == true { Chip("Awaiting", .awaiting) }
                if dep.type == .payroll {
                    Chip("↻ " + (dep.cadence?.label ?? "Payroll"), .payroll)
                } else {
                    Chip("One-time", .oneTime)
                }
                if dep.link != nil { Chip("Synced", .linked) }
                Chip(store.state.accountName(dep.accountId), .account)
                if showDate {
                    if let o = occurrence {
                        Chip(DayText.short(o.date) + (o.awaiting ? "" : " · " + DayText.relative(o.days).replacingOccurrences(of: "Due ", with: "")), .account)
                    } else {
                        Chip("No upcoming date", .account)
                    }
                }
            }
            .padding(.top, 7)
            HStack(spacing: 8) {
                if dep.type == .oneoff {
                    Button("Mark received") {
                        store.perform { s in
                            let added = s.markReceived(depositId: dep.id)
                            return "\(dep.name) received" + (added ? " · \(dep.amount.usd) added to \(s.accountName(dep.accountId))" : "")
                        }
                    }
                    .buttonStyle(.cardPrimary)
                }
                Button("Edit") { store.sheet = .editDeposit(dep.id) }.buttonStyle(.cardSubtle)
            }
            .padding(.top, 10)
        }
        .card(edge: Theme.good)
    }
}
