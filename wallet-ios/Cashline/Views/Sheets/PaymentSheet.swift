import SwiftUI
import CashlineCore

/// "Mark paid": records a payment now / in the past, or holds it until a
/// future date.
struct PaymentSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let billId: String

    @State private var amount = ""
    @State private var accountId: String?
    @State private var date = Date()
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            if let b = store.state.bill(billId) {
                let due = store.engine.nextDue(b)
                let picked = Day.today(now: date)
                let n = store.today.days(until: picked)
                Form {
                    Section {
                        Text("**\(b.name)** — \(b.amount.usd) statement, \(due.overdue ? "was due" : "due") \(DayText.short(due.date)).")
                            .font(.subheadline)
                        MoneyField(title: "Amount paid", text: $amount)
                        Picker("Paid from", selection: $accountId) {
                            Text("No account").tag(String?.none)
                            ForEach(store.state.accounts) { a in Text("\(a.name) — \(a.balance.usd)").tag(String?.some(a.id)) }
                        }
                    }
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(quickPicks(due), id: \.day) { pick in
                                    PillButton(title: pick.label, selected: picked == pick.day) { date = pick.day.date(hour: 12) ?? date }
                                }
                            }
                        }
                        DatePicker("Payment date", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                    } header: {
                        Text("Payment date")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(n > 0 ? "Held, then paid automatically on \(DayText.short(picked)) — in \(n) day\(n == 1 ? "" : "s"). The balance won't change and the bill stays covered until then."
                                 : n == 0 ? "Recorded as paid today." : "Recorded as already paid on \(DayText.short(picked)).")
                            Text("Due date: \(DayText.short(due.date))").foregroundStyle(due.overdue ? Theme.danger : Theme.warn)
                            if !store.state.settings.deductOnPaid {
                                Text("Automatic balance updates are off in Settings — this won't change the account balance.")
                            }
                        }
                    }
                }
                .navigationTitle("Record payment")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(n > 0 ? "Schedule" : "Record") { submit(b, on: picked) }
                    }
                }
                .onAppear {
                    guard !loaded else { return }
                    loaded = true
                    amount = moneyText(b.amount)
                    accountId = store.state.account(b.accountId)?.id
                }
            } else {
                ContentUnavailableView("Bill not found", systemImage: "questionmark.circle")
            }
        }
    }

    private struct QuickPick { var label: String; var day: Day }

    private func quickPicks(_ due: DueInfo) -> [QuickPick] {
        let t = store.today
        var out = [QuickPick(label: "Today", day: t)]
        if due.date > t {
            let before = due.date.adding(days: -1)
            if before > t { out.append(QuickPick(label: "Day before due", day: before)) }
            out.append(QuickPick(label: "On due date", day: due.date))
        }
        return out
    }

    private func submit(_ b: Bill, on day: Day) {
        let amt = max(0, parseMoney(amount) ?? 0)
        store.perform { s in
            switch s.recordPayment(billId: b.id, amount: amt, date: day, accountId: accountId, today: store.today) {
            case let .scheduled(d)?:
                return "Payment scheduled for \(DayText.short(d)) — \(b.name), \(amt.usd). Balance holds until then."
            case let .paid(deducted)?:
                return "\(b.name) paid — \(amt.usd)" + (deducted ? " from \(s.accountName(accountId))" : "")
            case nil:
                return nil
            }
        }
        dismiss()
    }
}
