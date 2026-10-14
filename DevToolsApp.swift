import SwiftUI

@main
struct DevToolsApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var purchases = PurchaseStore()
    @StateObject private var updater = PackageUpdater()
    @StateObject private var ads = AdManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(purchases)
                .environmentObject(updater)
                .environmentObject(ads)
                .tint(model.accent)
                .preferredColorScheme(model.colorScheme)
                .task {
                    purchases.onChange = {
                        model.reload()
                        ads.setPro(model.isPro)
                    }
                    await purchases.load()
                    await ads.prepare()
                    await updater.check(enabled: model.config.automaticallyInstallUpdates)
                }
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    if newPhase == .active {
                        model.reload()
                        ads.setPro(model.isPro)
                        if oldPhase == .background {
                            ads.foregrounded()
                        }
                        Task {
                            await purchases.refreshEntitlements()
                            await updater.check(enabled: model.config.automaticallyInstallUpdates)
                        }
                    }
                }
                .alert("DevTools", isPresented: Binding(get: {
                    model.error != nil
                }, set: { shown in
                    if !shown {
                        model.error = nil
                    }
                })) {
                    Button("OK", role: .cancel) {
                        model.error = nil
                    }
                } message: {
                    Text(model.error ?? "")
                }
        }
    }
}
