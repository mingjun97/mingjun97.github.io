import SwiftUI
import UniformTypeIdentifiers
import CashlineCore

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var exporting = false
    @State private var importing = false
    @State private var pendingImport: AppState?
    @State private var confirmErase = false
    @State private var confirmSample = false
    @State private var notificationsDenied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: leadDays, in: 0...30) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remind me \(store.state.settings.leadDays) day\(store.state.settings.leadDays == 1 ? "" : "s") ahead")
                            Text("Manual-pay bills raise an alert this many days before they're due.")
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Toggle(isOn: notifications) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notifications")
                            Text(notificationsDenied
                                 ? "Notifications are off for Cashline in iOS Settings."
                                 : "Reminders arrive on schedule even when Cashline is closed.")
                                .font(.caption).foregroundStyle(notificationsDenied ? Theme.danger : Theme.muted)
                        }
                    }
                    Toggle(isOn: deduct) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Update balances automatically")
                            Text("Subtract a bill from its account when marked paid, and add a deposit when marked received.")
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                } header: { Text("Reminders") }

                bankSection

                Section {
                    Button("Export backup", systemImage: "square.and.arrow.up") { exporting = true }
                    Button("Import backup", systemImage: "square.and.arrow.down") { importing = true }
                    Button("Load sample data", systemImage: "wand.and.stars") {
                        if store.state.bills.isEmpty { store.loadSample() } else { confirmSample = true }
                    }
                    Button("Erase everything", systemImage: "trash", role: .destructive) { confirmErase = true }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Your data stays on this iPhone unless you connect a bank. Backups use the same format as the Cashline web app, so you can move data between them.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Settings")
            .fileExporter(isPresented: $exporting, document: BackupDocument(state: store.state),
                          contentType: .json, defaultFilename: Backup.filename()) { result in
                if case .success = result { store.show("Backup saved") }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                handleImport(result)
            }
            .confirmationDialog("Replace all data with this backup?", isPresented: importBinding, titleVisibility: .visible) {
                Button("Replace", role: .destructive) {
                    if let s = pendingImport { store.replaceAll(with: s, message: "Backup imported") }
                    pendingImport = nil
                }
            } message: {
                Text("Everything currently on this iPhone will be replaced.")
            }
            .confirmationDialog("Erase everything?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Erase", role: .destructive) { store.eraseEverything() }
            } message: {
                Text("Deletes all accounts, bills, deposits and settings on this iPhone.")
            }
            .confirmationDialog("Replace your data with sample data?", isPresented: $confirmSample, titleVisibility: .visible) {
                Button("Load sample data", role: .destructive) { store.loadSample() }
            }
            .task {
                if store.state.settings.notificationsEnabled {
                    let ok = await store.notifications.isAuthorized()
                    notificationsDenied = !ok
                }
            }
        }
    }

    // MARK: bank connections

    @ViewBuilder
    private var bankSection: some View {
        @Bindable var store = store
        Section {
            Picker("Connection", selection: $store.backend.mode) {
                ForEach(BackendSettings.Mode.allCases) { Text($0.label).tag($0) }
            }
            if store.backend.mode == .server {
                TextField("https://api.example.com", text: $store.backend.serverURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if store.backend.mode != .off {
                ForEach(store.state.linkedItems) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.institutionName ?? "Bank")
                            Text(item.needsReauth ? "Needs you to sign in again" : "Connected")
                                .font(.caption).foregroundStyle(item.needsReauth ? Theme.warn : Theme.muted)
                        }
                        Spacer()
                        Button("Disconnect", role: .destructive) { Task { await store.unlink(item) } }
                            .font(.footnote)
                    }
                }
                Button {
                    Task { await store.linkBank() }
                } label: {
                    HStack {
                        Label("Connect a bank", systemImage: "plus.circle")
                        if store.isSyncing { Spacer(); ProgressView() }
                    }
                }
                .disabled(store.isSyncing || store.bankBackend == nil)
                if !store.state.linkedItems.isEmpty {
                    Button("Sync now", systemImage: "arrow.clockwise") { Task { await store.sync() } }
                        .disabled(store.isSyncing)
                }
                if let err = store.syncError {
                    Text(err).font(.caption).foregroundStyle(Theme.danger)
                }
            }
        } header: {
            Text("Bank connections")
        } footer: {
            Text(bankFooter)
        }
    }

    private var bankFooter: String {
        switch store.backend.mode {
        case .off: return "Off: everything is entered by hand. Turn on to pull balances, card statements and payroll automatically through Plaid."
        case .demo: return "Demo bank uses made-up data so you can try connecting without a server."
        case .server: return "Uses your Cashline server, which talks to Plaid. Bank passwords and Plaid keys never touch this iPhone."
        }
    }

    // MARK: bindings

    private var leadDays: Binding<Int> {
        Binding(get: { store.state.settings.leadDays },
                set: { v in store.update { $0.settings.leadDays = v } })
    }

    private var deduct: Binding<Bool> {
        Binding(get: { store.state.settings.deductOnPaid },
                set: { v in store.update { $0.settings.deductOnPaid = v } })
    }

    private var notifications: Binding<Bool> {
        Binding(get: { store.state.settings.notificationsEnabled },
                set: { on in
                    if !on {
                        store.update { $0.settings.notificationsEnabled = false }
                        notificationsDenied = false
                        return
                    }
                    Task {
                        let ok = await store.notifications.requestAuthorization()
                        notificationsDenied = !ok
                        store.update { $0.settings.notificationsEnabled = ok }
                        if ok { store.show("Reminders are on") }
                    }
                })
    }

    private var importBinding: Binding<Bool> {
        Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let decoded = try Backup.decode(Data(contentsOf: url))
            // let the document picker finish dismissing before asking
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                pendingImport = decoded
            }
        } catch {
            store.show(Backup.BackupError.notABackup.localizedDescription)
        }
    }
}

/// Wraps the state as a JSON file for the system file exporter.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var state: AppState

    init(state: AppState) { self.state = state }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw Backup.BackupError.notABackup }
        state = try Backup.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try Backup.encode(state))
    }
}
