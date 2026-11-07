import SwiftUI
import CashlineCore

struct AccountsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text("Keep balances current — Cashline flags any account that can't cover what's about to be drafted.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                    if store.backend.mode != .off { BankBanner() }
                    if store.state.accounts.isEmpty {
                        EmptyCard(title: "No checking accounts yet.",
                                  message: "Add each checking account and its current balance so Cashline can warn you before an autopay overdraws it.") {
                            Button("Add an account") { store.sheet = .newAccount }.buttonStyle(.cardPrimary)
                        }
                    } else {
                        ForEach(store.state.accounts) { AccountCard(account: $0) }
                        if store.state.accounts.count > 1 {
                            Text("Tip: drag one account onto another to move money between them.")
                                .font(.caption).foregroundStyle(Theme.faint).padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 90)
            }
            .background(Theme.bg)
            .navigationTitle("Accounts")
            .refreshable { await store.sync() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.sheet = .newAccount } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                        .accessibilityLabel("Add account")
                }
            }
        }
    }
}

/// Connect / sync banner shown when bank connections are turned on.
private struct BankBanner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link.circle.fill").font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.state.linkedItems.isEmpty ? "Connect your bank" : "\(store.state.linkedItems.count) bank\(store.state.linkedItems.count == 1 ? "" : "s") connected")
                    .fontWeight(.semibold)
                Text(store.syncError ?? subtitle).font(.caption)
                    .foregroundStyle(store.syncError == nil ? Theme.muted : Theme.danger)
            }
            Spacer()
            if store.isSyncing {
                ProgressView()
            } else if store.state.linkedItems.isEmpty {
                Button("Connect") { Task { await store.linkBank() } }.buttonStyle(.cardPrimary)
            } else {
                Button("Sync") { Task { await store.sync() } }.buttonStyle(.cardGhost)
            }
        }
        .card()
    }

    private var subtitle: String {
        if store.state.linkedItems.isEmpty { return "Balances, card statements and payroll fill in automatically." }
        if let last = store.backend.lastSync { return "Last synced \(last.formatted(.relative(presentation: .named)))" }
        return "Not synced yet"
    }
}

private struct AccountCard: View {
    @Environment(AppStore.self) private var store
    let account: Account
    @State private var isDropTarget = false

    var body: some View {
        let a = account
        let s = store.state
        let p = store.engine.projection(for: a)
        let nBills = s.bills.filter { $0.accountId == a.id }.count
        let nDeps = s.deposits.filter { $0.accountId == a.id }.count
        let available = a.balance + p.inflow
        let fraction = p.outflow <= 0 ? 0 : min(1, p.outflow / max(available, p.outflow))

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.name).fontWeight(.semibold).lineLimit(1)
                    HStack(spacing: 4) {
                        Text("\(nBills) bill\(nBills == 1 ? "" : "s")" + (nDeps > 0 ? " · \(nDeps) deposit\(nDeps == 1 ? "" : "s")" : ""))
                        if a.link != nil { Image(systemName: "link").accessibilityLabel("Synced") }
                    }
                    .font(.footnote).foregroundStyle(Theme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(a.balance.usd).font(.title3.monospacedDigit().weight(.semibold))
                    Text("balance").font(.footnote).foregroundStyle(Theme.muted)
                }
            }
            ProgressView(value: fraction)
                .tint(p.dipsBelowZero ? Theme.danger : Theme.accent)
                .padding(.top, 10)
                .accessibilityLabel("\(p.outflow.usd) going out of \(available.usd) available")
            HStack {
                Text("30 days: out \(p.outflow.usd)" + (p.inflow > 0 ? " · in +\(p.inflow.usd)" : ""))
                Spacer()
                Text(p.dipsBelowZero ? "Dips \((-p.minimum).usd) short ~\(DayText.short(p.minimumDate))" : "ends at \(p.end.usd)")
                    .foregroundStyle(p.dipsBelowZero ? Theme.danger : Theme.muted)
            }
            .font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
            .lineLimit(1).minimumScaleFactor(0.75)
            .padding(.top, 5)
            HStack(spacing: 8) {
                Button("Update balance") { store.sheet = .editAccount(a.id) }.buttonStyle(.cardGhost)
                if s.accounts.count > 1 {
                    Button("Transfer") { store.sheet = .transfer(from: a.id, to: nil) }.buttonStyle(.cardGhost)
                }
            }
            .padding(.top, 10)
        }
        .card()
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.accent, lineWidth: isDropTarget ? 2 : 0))
        .draggable(a.id) {
            Label(a.name, systemImage: "arrow.left.arrow.right")
                .padding(10).background(.regularMaterial, in: Capsule())
        }
        .dropDestination(for: String.self) { items, _ in
            guard let from = items.first, from != a.id, store.state.account(from) != nil else { return false }
            store.sheet = .transfer(from: from, to: a.id)
            return true
        } isTargeted: { isDropTarget = $0 }
    }
}
