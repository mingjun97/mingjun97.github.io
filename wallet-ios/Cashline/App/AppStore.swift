import SwiftUI
import Observation
import CashlineCore

enum AppTab: Hashable { case home, bills, accounts, settings }

/// Every editor / sheet the app can show. Any view can open one by setting
/// `store.sheet`.
enum ActiveSheet: Identifiable, Hashable {
    case newBill
    case editBill(String)
    case newAccount
    case editAccount(String)
    case newDeposit
    case editDeposit(String)
    case pay(String)
    case balance(String)
    case transfer(from: String, to: String?)

    var id: String {
        switch self {
        case .newBill: return "newBill"
        case let .editBill(id): return "editBill-\(id)"
        case .newAccount: return "newAccount"
        case let .editAccount(id): return "editAccount-\(id)"
        case .newDeposit: return "newDeposit"
        case let .editDeposit(id): return "editDeposit-\(id)"
        case let .pay(id): return "pay-\(id)"
        case let .balance(id): return "balance-\(id)"
        case let .transfer(from, to): return "transfer-\(from)-\(to ?? "")"
        }
    }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    /// State to restore if the person taps Undo.
    var undo: AppState?
}

/// The app's single source of truth: owns the state, saves it, and runs the
/// time-based bookkeeping (posting scheduled payments, folding statements).
@MainActor
@Observable
final class AppStore {
    private(set) var state: AppState
    private(set) var today: Day
    var toast: ToastMessage?
    var sheet: ActiveSheet?
    var tab: AppTab = .home
    var isSyncing = false
    var syncError: String?
    var backend: BackendSettings {
        didSet { backend.save() }
    }

    @ObservationIgnored private let store: StateStore
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var rescheduleTask: Task<Void, Never>?
    @ObservationIgnored let notifications = NotificationService()
    @ObservationIgnored private var mockBackend: MockCashlineBackend?

    init(store: StateStore) {
        self.store = store
        self.state = (try? store.load()) ?? AppState()
        self.today = Day.today()
        self.backend = BackendSettings.load()
        refresh(announce: false)
    }

    var engine: Engine { Engine(state: state, today: today) }

    // MARK: changing state

    /// Applies a change, saves, and shows `message` with an Undo button.
    func update(_ message: String? = nil, undoable: Bool = true, _ change: (inout AppState) -> Void) {
        let before = state
        change(&state)
        persist()
        if let message { show(message, undo: undoable ? before : nil) }
    }

    /// Like `update`, but the change returns the message (for wording that
    /// depends on what happened).
    func perform(undoable: Bool = true, _ change: (inout AppState) -> String?) {
        let before = state
        let message = change(&state)
        persist()
        if let message { show(message, undo: undoable ? before : nil) }
    }

    func undo() {
        guard let previous = toast?.undo else { return }
        state = previous
        persist()
        withAnimation { toast = nil }
    }

    func show(_ text: String, undo: AppState? = nil) {
        withAnimation(.snappy) { toast = ToastMessage(text: text, undo: undo) }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation { self?.toast = nil }
        }
    }

    private func persist() {
        do { try store.save(state) } catch { print("Cashline: save failed: \(error)") }
        scheduleReminders()
    }

    // MARK: time passing

    /// Re-reads today's date and applies anything that came due: scheduled
    /// payments post, pending charges fold into new statements.
    func refresh(announce: Bool = true) {
        today = Day.today()
        var s = state
        let folded = s.processBillRolls(today: today)
        let posted = s.processScheduled(today: today)
        if s != state {
            state = s
            persist()
        } else {
            scheduleReminders()
        }
        guard announce else { return }
        if posted.count == 1, let p = posted.first {
            show("Scheduled payment posted — \(p.name), \(p.amount.usd)")
        } else if posted.count > 1 {
            show("\(posted.count) scheduled payments posted")
        } else if folded.count == 1, let f = folded.first {
            show("\(f.amount.usd) in posted charges moved onto \(f.name)'s statement")
        } else if folded.count > 1 {
            show("Posted charges moved onto \(folded.count) statements")
        }
    }

    func refreshIfDayChanged() {
        if Day.today() != today { refresh() }
    }

    private func scheduleReminders() {
        rescheduleTask?.cancel()
        let snapshot = state, day = today, attention = engine.attentionCount()
        rescheduleTask = Task { [notifications] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await notifications.reschedule(snapshot, today: day)
            await notifications.setBadge(snapshot.settings.notificationsEnabled ? attention : 0)
        }
    }

    // MARK: data

    func replaceAll(with newState: AppState, message: String) {
        update(message) { $0 = newState }
        refresh(announce: false)
    }

    func loadSample() {
        update("Sample data loaded — erase it anytime in Settings.") { s in
            let sample = AppState.sample(today: today)
            s.accounts = sample.accounts
            s.bills = sample.bills
            s.deposits = sample.deposits
            s.scheduled = sample.scheduled
        }
    }

    func eraseEverything() {
        update("Everything erased") { $0 = AppState() }
    }

    // MARK: bank connections

    /// The configured backend, or nil when bank connections are off.
    var bankBackend: CashlineBackend? {
        switch backend.mode {
        case .off: return nil
        case .demo:
            if mockBackend == nil { mockBackend = MockCashlineBackend() }
            return mockBackend
        case .server:
            guard let url = URL(string: backend.serverURL), url.scheme?.hasPrefix("http") == true else { return nil }
            return HTTPCashlineBackend(baseURL: url, authToken: { await AuthTokenStore.shared.token() })
        }
    }

    /// Links a new institution through Plaid Link, then syncs.
    func linkBank() async {
        guard let api = bankBackend else { syncError = BackendError.notConfigured.localizedDescription; return }
        isSyncing = true; syncError = nil
        defer { isSyncing = false }
        do {
            let linkToken = try await api.createLinkToken(updateItemId: nil)
            let result: PlaidLinkResult
            if backend.mode == .demo {
                result = PlaidLinkResult(publicToken: "public-sandbox-demo", institutionName: "Demo Bank")
            } else {
                guard let r = try await PlaidLinkPresenter.open(linkToken: linkToken) else { return } // closed by the person
                result = r
            }
            _ = try await api.exchangePublicToken(result.publicToken, institutionName: result.institutionName)
            try await syncNow(api)
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Pulls the latest balances, statements and paydays.
    func sync() async {
        guard let api = bankBackend else { return }
        isSyncing = true; syncError = nil
        defer { isSyncing = false }
        do { try await syncNow(api) } catch { syncError = error.localizedDescription }
    }

    private func syncNow(_ api: CashlineBackend) async throws {
        let snap = try await api.fetchSnapshot()
        var report = SyncReport()
        update(nil) { report = SyncMerger.merge(snap, into: &$0, today: today) }
        backend.lastSync = Date()
        show(report.summary)
    }

    /// Syncs on launch / foreground if the last sync is stale.
    func syncIfStale() async {
        guard bankBackend != nil, !state.linkedItems.isEmpty else { return }
        if let last = backend.lastSync, Date().timeIntervalSince(last) < 15 * 60 { return }
        await sync()
    }

    /// Disconnects an institution. Its accounts and bills stay, as manual records.
    func unlink(_ item: LinkedItem) async {
        guard let api = bankBackend else { return }
        do {
            try await api.removeItem(id: item.id)
            update("\(item.institutionName ?? "Bank") disconnected — its records are now manual", undoable: false) { s in
                s.linkedItems.removeAll { $0.id == item.id }
                for i in s.accounts.indices where s.accounts[i].link?.itemId == item.id { s.accounts[i].link = nil }
                for i in s.bills.indices where s.bills[i].link?.itemId == item.id { s.bills[i].link = nil }
                for i in s.deposits.indices where s.deposits[i].link?.itemId == item.id { s.deposits[i].link = nil }
            }
        } catch {
            syncError = error.localizedDescription
        }
    }
}
