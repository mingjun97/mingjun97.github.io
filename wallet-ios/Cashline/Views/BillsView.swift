import SwiftUI
import CashlineCore

struct BillsView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var iconFilter: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text("Tap Balance when a new statement arrives.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                    if store.state.bills.count > 0 { iconChips }
                    billSections
                    if iconFilter == nil { depositSection }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 90)
            }
            .background(Theme.bg)
            .navigationTitle("Bills & deposits")
            .searchable(text: $query, prompt: "Search bills or accounts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add a bill", systemImage: "doc.badge.plus") { store.sheet = .newBill }
                        Button("Add a deposit", systemImage: "arrow.down.to.line") { addDeposit() }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                    .accessibilityLabel("Add")
                }
            }
        }
    }

    private func matches(_ name: String, _ accountId: String?) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || name.lowercased().contains(q) || store.state.accountName(accountId).lowercased().contains(q)
    }

    private var iconChips: some View {
        let used = Set(store.state.bills.map(\.iconID))
        let ordered = BillIcon.ordered.filter { used.contains($0.id) }
        return Group {
            if ordered.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(selected: iconFilter == nil) { iconFilter = nil } label: {
                            Text("All").font(.footnote.weight(.semibold)).padding(.horizontal, 10)
                        }
                        ForEach(ordered, id: \.id) { icon in
                            FilterChip(selected: iconFilter == icon.id) {
                                iconFilter = iconFilter == icon.id ? nil : icon.id
                            } label: {
                                BillIconView(id: icon.id, size: 26)
                            }
                            .accessibilityLabel("Filter: \(icon.label)")
                        }
                    }
                    .padding(2)
                }
            }
        }
    }

    @ViewBuilder
    private var billSections: some View {
        let list = store.engine.allBillsByDue().filter { x in
            (iconFilter == nil || x.bill.iconID == iconFilter) && matches(x.bill.name, x.bill.accountId)
        }
        if store.state.bills.isEmpty {
            EmptyCard(title: "No bills yet.",
                      message: "Add each credit card and utility bill with its due day, amount, and the checking account it pays from.") {
                Button("Add a bill") { store.sheet = .newBill }.buttonStyle(.cardPrimary)
            }
        } else if list.isEmpty {
            EmptyCard(title: "No bills match.", message: "Nothing named like that\(iconFilter == nil ? "" : " with this icon").") {
                Button("Clear filter") { query = ""; iconFilter = nil }.buttonStyle(.cardGhost)
            }
        } else {
            let cards = list.filter { $0.bill.kind == .card }
            let utils = list.filter { $0.bill.kind != .card }
            if !cards.isEmpty {
                Text("Credit cards").sectionLabelStyle().padding(.top, 8)
                ForEach(cards) { BillCard(item: $0, showDate: true) }
            }
            if !utils.isEmpty {
                Text("Utilities & other").sectionLabelStyle().padding(.top, 8)
                ForEach(utils) { BillCard(item: $0, showDate: true) }
            }
        }
    }

    @ViewBuilder
    private var depositSection: some View {
        let e = store.engine
        let deps = store.state.deposits.filter { matches($0.name, $0.accountId) }
            .map { DepositRow(dep: $0, occ: e.occurrences(of: $0, within: 62).first) }
            .sorted { ($0.occ?.date.ordinal ?? .max) < ($1.occ?.date.ordinal ?? .max) }
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        if !(searching && deps.isEmpty) {
            HStack {
                Text("Expected deposits").sectionLabelStyle()
                Spacer()
                Button("+ Add deposit") { addDeposit() }.font(.footnote.weight(.semibold))
            }
            .padding(.top, 14)
            if deps.isEmpty {
                Text("Track incoming money — a one-time payout or payroll on a schedule — and projections will count it.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                    .padding(18).frame(maxWidth: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            } else {
                ForEach(deps) { d in
                    DepositCard(deposit: d.dep, occurrence: d.occ, showDate: true)
                }
            }
        }
    }

    private func addDeposit() {
        if store.state.accounts.isEmpty {
            store.show("Add a checking account first — deposits need an account to land in.")
            store.tab = .accounts
        } else {
            store.sheet = .newDeposit
        }
    }
}

private struct DepositRow: Identifiable {
    var dep: Deposit
    var occ: DepositOccurrence?
    var id: String { dep.id }
}

private struct FilterChip<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            label
                .frame(minHeight: 26)
                .padding(4)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 2 : 1))
                .foregroundStyle(selected ? Theme.accent : Theme.muted)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
