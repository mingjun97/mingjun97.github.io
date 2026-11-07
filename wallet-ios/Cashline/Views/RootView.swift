import SwiftUI
import CashlineCore

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .badge(store.engine.attentionCount())
                .tag(AppTab.home)
            BillsView()
                .tabItem { Label("Bills", systemImage: "list.bullet.rectangle") }
                .tag(AppTab.bills)
            AccountsView()
                .tabItem { Label("Accounts", systemImage: "building.columns") }
                .tag(AppTab.accounts)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(toast: toast)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 58)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $store.sheet) { sheet in
            Group {
                switch sheet {
                case .newBill: BillEditor(billId: nil)
                case let .editBill(id): BillEditor(billId: id)
                case .newAccount: AccountEditor(accountId: nil)
                case let .editAccount(id): AccountEditor(accountId: id)
                case .newDeposit: DepositEditor(depositId: nil)
                case let .editDeposit(id): DepositEditor(depositId: id)
                case let .pay(id): PaymentSheet(billId: id)
                case let .balance(id): BalanceSheet(billId: id)
                case let .transfer(from, to): TransferSheet(fromId: from, toId: to)
                }
            }
            .environment(store)
            .tint(Theme.accent)
        }
    }
}

struct ToastView: View {
    @Environment(AppStore.self) private var store
    let toast: ToastMessage

    var body: some View {
        HStack(spacing: 14) {
            Text(toast.text)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            if toast.undo != nil {
                Button("Undo") { store.undo() }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .frame(maxWidth: 480)
        .onTapGesture { withAnimation { store.toast = nil } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
