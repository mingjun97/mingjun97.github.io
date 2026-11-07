import SwiftUI
import CashlineCore

struct DepositEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let depositId: String?

    @State private var name = ""
    @State private var amount = ""
    @State private var accountId: String?
    @State private var type: DepositType = .oneoff
    @State private var date = Date()
    @State private var cadence: Cadence = .biweekly
    @State private var anchor = Date()
    @State private var day1 = 15
    @State private var day2 = 31
    @State private var monthlyDay = 1
    @State private var loaded = false

    private var existing: Deposit? { store.state.deposits.first { $0.id == depositId } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Payroll — Acme, eBay payout", text: $name)
                    MoneyField(title: "Amount", text: $amount)
                    Picker("Deposits into", selection: $accountId) {
                        ForEach(store.state.accounts) { a in Text(a.name).tag(String?.some(a.id)) }
                    }
                }
                Section {
                    Picker("Type", selection: $type.animation()) {
                        Text("One-time").tag(DepositType.oneoff)
                        Text("Payroll / recurring").tag(DepositType.payroll)
                    }
                    .pickerStyle(.segmented)
                    if type == .oneoff {
                        DatePicker("Expected date", selection: $date, displayedComponents: .date)
                    } else {
                        Picker("Cadence", selection: $cadence.animation()) {
                            ForEach(Cadence.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        switch cadence {
                        case .weekly, .biweekly:
                            DatePicker("Next payday", selection: $anchor, displayedComponents: .date)
                        case .semimonthly:
                            Stepper("First payday: \(day1)", value: $day1, in: 1...31)
                            Stepper("Second payday: \(day2 == 31 ? "last day" : "\(day2)")", value: $day2, in: 1...31)
                        case .monthly:
                            Stepper("Day of month: \(monthlyDay == 31 ? "last day" : "\(monthlyDay)")", value: $monthlyDay, in: 1...31)
                        }
                    }
                } footer: {
                    if type == .payroll && cadence == .semimonthly { Text("31 means the last day of the month.") }
                    else if existing?.link != nil { Text("Detected from your bank. The amount and schedule update on every sync.") }
                }
                if let d = existing {
                    Section {
                        Button("Delete deposit", role: .destructive) {
                            store.update("\(d.name) deleted") { $0.deleteDeposit(id: d.id) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add an expected deposit" : "Edit deposit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(trimmedName.isEmpty || accountId == nil) }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let d = existing else {
            accountId = store.state.accounts.first?.id
            return
        }
        name = d.name; amount = moneyText(d.amount); accountId = d.accountId; type = d.type
        if let iso = d.date, let day = Day(iso: iso), let dt = day.date(hour: 12) { date = dt }
        cadence = d.cadence ?? .biweekly
        if let iso = d.anchor, let day = Day(iso: iso), let dt = day.date(hour: 12) { anchor = dt }
        if cadence == .monthly { monthlyDay = d.day1 ?? 1 } else { day1 = d.day1 ?? 15; day2 = d.day2 ?? 31 }
    }

    private func save() {
        var d = existing ?? Deposit(name: "", amount: 0, accountId: accountId, type: type)
        d.name = String(trimmedName.prefix(40))
        d.amount = max(0, cents(parseMoney(amount) ?? 0))
        d.accountId = accountId
        d.type = type
        // replace recurrence fields wholesale so stale ones don't linger
        d.date = nil; d.cadence = nil; d.anchor = nil; d.day1 = nil; d.day2 = nil
        if type == .oneoff {
            d.date = Day.today(now: date).iso
        } else {
            d.cadence = cadence
            switch cadence {
            case .weekly, .biweekly: d.anchor = Day.today(now: anchor).iso
            case .semimonthly: d.day1 = day1; d.day2 = day2
            case .monthly: d.day1 = monthlyDay
            }
        }
        let isNew = existing == nil
        store.update("\(d.name) \(isNew ? "added" : "updated")") { $0.upsertDeposit(d) }
        dismiss()
    }
}
