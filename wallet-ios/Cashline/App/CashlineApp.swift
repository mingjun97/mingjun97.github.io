import SwiftUI
import CashlineCore

@main
struct CashlineApp: App {
    @State private var store: AppStore = {
        let fileStore: StateStore = (try? JSONFileStore.appDefault()) ?? MemoryStore()
        return AppStore(store: fileStore)
    }()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(Theme.accent)
                .task {
                    // keep "today" right across midnight while the app stays open
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        store.refreshIfDayChanged()
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.refresh()
            Task { await store.syncIfStale() }
        }
    }
}
