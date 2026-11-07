import SwiftUI
import CashlineCore

struct BillEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let billId: String?

    @State private var name = ""
    @State private var kind: BillKind = .card
    @State private var icon = "card"
    @State private var iconTouched = false
    @State private var amount = ""
    @State private var dueDay = 1
    @State private var accountId: String?
    @State private var autopay = false
    @State private var autopayMode: AutopayMode = .full
    @State private var autopayAmount = ""
    @State private var loaded = false

    private var existing: Bill? { store.state.bill(billId) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Chase Sapphire, PG&E", text: $name)
                        .textInputAutocapitalization(.words)
                    Picker("Type", selection: $kind) {
                        Text("Credit card").tag(BillKind.card)
                        Text("Utility / other").tag(BillKind.utility)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        ForEach(BillIcon.ordered, id: \.id) { i in
                            Button {
                                icon = i.id; iconTouched = true
                            } label: {
                                BillIconView(id: i.id, size: 30)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(icon == i.id ? Theme.accent : Theme.line, lineWidth: icon == i.id ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(i.label)
                            .accessibilityAddTraits(icon == i.id ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    MoneyField(title: "Amount due", text: $amount)
                    Picker("Due day of month", selection: $dueDay) {
                        ForEach(1...31, id: \.self) { Text(ordinal($0)).tag($0) }
                    }
                    Picker("Pays from", selection: $accountId) {
                        Text("No account").tag(String?.none)
                        ForEach(store.state.accounts) { a in Text(a.name).tag(String?.some(a.id)) }
                    }
                } footer: {
                    Text(dueDay > 28 ? "In shorter months it's due on the last day." : "The checking account this bill is paid from.")
                }
                Section {
                    Toggle("Autopay is on", isOn: $autopay.animation())
                    if autopay {
                        Picker("Autopay draws", selection: $autopayMode.animation()) {
                            Text("Full balance").tag(AutopayMode.full)
                            Text("Fixed amount").tag(AutopayMode.fixed)
                        }
                        .pickerStyle(.segmented)
                        if autopayMode == .fixed {
                            MoneyField(title: "Fixed payment", text: $autopayAmount, prompt: "150.00")
                        }
                    }
                } footer: {
                    Text(autopay && autopayMode == .fixed
                         ? "This amount is drafted every cycle regardless of the statement balance."
                         : "Autopay bills roll to next month on their due date. Bills without autopay wait for you to mark them paid.")
                }
                if let b = existing {
                    if b.link != nil {
                        Section { Text("Synced from \(b.link?.institution ?? "your bank"). The amount and due day update on every sync.").font(.footnote).foregroundStyle(Theme.muted) }
                    }
                    Section {
                        Button("Delete bill", role: .destructive) {
                            store.update("\(b.name) deleted") { $0.deleteBill(id: b.id) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(billId == nil ? "Add a bill" : "Edit bill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(trimmedName.isEmpty) }
            }
            .onChange(of: name) { _, n in if !iconTouched { icon = BillIcon.suggest(name: n, kind: kind) } }
            .onChange(of: kind) { _, k in if !iconTouched { icon = BillIcon.suggest(name: name, kind: k) } }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let b = existing {
            name = b.name; kind = b.kind; icon = b.iconID; iconTouched = b.icon != nil
            amount = moneyText(b.amount); dueDay = b.dueDay; accountId = b.accountId
            autopay = b.autopay; autopayMode = b.autopayMode; autopayAmount = moneyText(b.autopayAmount)
        } else {
            accountId = store.state.accounts.first?.id
            dueDay = store.today.day
        }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        var b = existing ?? Bill(name: trimmedName, kind: kind, amount: 0, dueDay: dueDay, accountId: accountId, autopay: autopay)
        b.name = String(trimmedName.prefix(40))
        b.kind = kind
        b.icon = icon
        b.amount = max(0, cents(parseMoney(amount) ?? 0))
        b.dueDay = dueDay
        b.accountId = accountId
        b.autopay = autopay
        b.autopayMode = autopay ? autopayMode : .full
        b.autopayAmount = autopay && autopayMode == .fixed ? max(0, cents(parseMoney(autopayAmount) ?? 0)) : 0
        let isNew = existing == nil
        store.update("\(b.name) \(isNew ? "added" : "updated")") { $0.upsertBill(b, today: store.today) }
        dismiss()
    }

    private func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (1, let t) where t != 11: suffix = "st"
        case (2, let t) where t != 12: suffix = "nd"
        case (3, let t) where t != 13: suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}
