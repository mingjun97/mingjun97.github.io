import SwiftUI
import CashlineCore

/// Set the statement's amount due, or post a charge to the next statement.
struct BalanceSheet: View {
    enum Mode: Hashable { case set, post }
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let billId: String

    @State private var mode: Mode = .set
    @State private var amount = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            if let b = store.state.bill(billId) {
                let due = store.engine.nextDue(b)
                Form {
                    Section {
                        Text("Due \(DayText.short(due.date)) · \(b.amount.usd) statement" + (b.pending > 0 ? " · \(b.pending.usd) pending next statement" : ""))
                            .font(.subheadline).foregroundStyle(Theme.muted)
                        Picker("Operation", selection: $mode) {
                            Text("Set amount due").tag(Mode.set)
                            Text("Post to next stmt").tag(Mode.post)
                        }
                        .pickerStyle(.segmented)
                    }
                    Section {
                        MoneyField(title: mode == .set ? "Amount due" : "Post to next statement", text: $amount,
                                   allowNegative: mode == .post, prompt: mode == .set ? "0.00" : "120.00 or -20")
                    } footer: {
                        Text(footer(b, due: due))
                    }
                }
                .navigationTitle("Balance — \(b.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(mode == .set ? "Save" : "Post") { save(b) } }
                }
                .onChange(of: mode) { _, m in amount = m == .set ? moneyText(b.amount) : "" }
                .onAppear {
                    guard !loaded else { return }
                    loaded = true
                    amount = moneyText(b.amount)
                }
            }
        }
    }

    private func footer(_ b: Bill, due: DueInfo) -> String {
        if mode == .set { return "The current statement, due \(DayText.short(due.date))." }
        let pending = b.pending > 0 ? "Pending so far: \(b.pending.usd). " : ""
        return pending + "Held out of the current amount due; folds in automatically after \(DayText.short(due.date)) passes. A negative amount corrects."
    }

    private func save(_ b: Bill) {
        let amt = parseMoney(amount) ?? 0
        if mode == .set {
            store.update("\(b.name) — amount due set to \(max(0, cents(amt)).usd)") { $0.setAmountDue(billId: b.id, amount: amt) }
        } else if amt != 0 {
            store.perform { s in
                s.postToNextStatement(billId: b.id, amount: amt)
                return "\(amt.usd) posted to \(b.name)'s next statement — now \((s.bill(b.id)?.pending ?? 0).usd) pending"
            }
        }
        dismiss()
    }
}

struct AccountEditor: View {
    enum Mode: Hashable { case set, post }
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let accountId: String?

    @State private var name = ""
    @State private var mode: Mode = .set
    @State private var amount = ""
    @State private var loaded = false
    @State private var confirmDelete = false

    private var existing: Account? { store.state.account(accountId) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Account name, e.g. Chase Checking …1234", text: $name)
                    if existing != nil {
                        Picker("Balance update", selection: $mode) {
                            Text("Set balance").tag(Mode.set)
                            Text("Post amount").tag(Mode.post)
                        }
                        .pickerStyle(.segmented)
                    }
                    MoneyField(title: mode == .post ? "Amount to post" : "Current balance", text: $amount,
                               allowNegative: true, prompt: mode == .post ? "500 or -25" : "0.00")
                } footer: {
                    if mode == .post, let a = existing, let amt = parseMoney(amount) {
                        Text("New balance: \(cents(a.balance + amt).usd)")
                    } else if mode == .post {
                        Text("Adds onto the current balance — use a negative amount to subtract.")
                    } else if existing?.link != nil {
                        Text("This account syncs from your bank; the next sync replaces a balance set here.")
                    }
                }
                if let a = existing {
                    Section {
                        Button("Delete account", role: .destructive) {
                            if store.state.bills.contains(where: { $0.accountId == a.id }) { confirmDelete = true } else { delete(a) }
                        }
                    }
                }
            }
            .confirmationDialog("Delete account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                if let a = existing { Button("Delete", role: .destructive) { delete(a) } }
            } message: {
                let n = store.state.bills.filter { $0.accountId == accountId }.count
                Text("\(existing?.name ?? "This account") has \(n) linked bill\(n == 1 ? "" : "s"). They'll keep their data but show “No account”.")
            }
            .navigationTitle(existing == nil ? "Add a checking account" : "Update account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(trimmedName.isEmpty) }
            }
            .onChange(of: mode) { _, m in amount = m == .post ? "" : moneyText(existing?.balance ?? 0) }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let a = existing { name = a.name; amount = moneyText(a.balance) }
            }
        }
    }

    private func save() {
        let amt = cents(parseMoney(amount) ?? 0)
        let n = String(trimmedName.prefix(40))
        if var a = existing {
            a.name = n
            if mode == .post {
                a.balance = cents(a.balance + amt)
                store.update("\(amt.usd) posted to \(n) — balance \(a.balance.usd)") { $0.upsertAccount(a) }
            } else {
                a.balance = amt
                store.update("\(n) updated") { $0.upsertAccount(a) }
            }
        } else {
            store.update("\(n) added") { $0.upsertAccount(Account(name: n, balance: amt)) }
        }
        dismiss()
    }

    private func delete(_ a: Account) {
        store.update("\(a.name) deleted") { $0.deleteAccount(id: a.id) }
        dismiss()
    }
}

struct TransferSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let fromId: String
    let toId: String?

    @State private var to: String?
    @State private var amount = ""

    var body: some View {
        NavigationStack {
            if let from = store.state.account(fromId) {
                let others = store.state.accounts.filter { $0.id != fromId }
                Form {
                    Section {
                        LabeledContent("From") {
                            Text("\(from.name) · \(from.balance.usd)").foregroundStyle(Theme.muted)
                        }
                        Picker("To", selection: $to) {
                            ForEach(others) { a in Text("\(a.name) — \(a.balance.usd)").tag(String?.some(a.id)) }
                        }
                        MoneyField(title: "Amount", text: $amount)
                    }
                }
                .navigationTitle("Transfer")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Transfer") { transfer(from) }.disabled((parseMoney(amount) ?? 0) <= 0 || to == nil)
                    }
                }
                .onAppear { if to == nil { to = toId ?? others.first?.id } }
            }
        }
        .presentationDetents([.medium])
    }

    private func transfer(_ from: Account) {
        guard let to, let amt = parseMoney(amount) else { return }
        store.update("Moved \(cents(amt).usd) from \(from.name) to \(store.state.accountName(to))") {
            $0.transfer(from: from.id, to: to, amount: amt)
        }
        dismiss()
    }
}
