import SwiftUI
import StoreKit

struct ProView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: PurchaseStore
    @EnvironmentObject private var ads: AdManager

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.largeTitle)
                        .foregroundStyle(.purple)
                    Text("Your console, upgraded.")
                        .font(.largeTitle.bold())
                    Text("DevTools Pro")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Label("Vue component inspection", systemImage: "square.stack.3d.up")
                    Label("Resource timing & waterfall", systemImage: "chart.bar.xaxis")
                    Label("Extra plugins & console customization", systemImage: "slider.horizontal.3")
                    Label("An ad-free app", systemImage: "checkmark.seal")
                }
                .padding(.vertical, 10)
            }
            if model.isPro {
                Section {
                    Label("Pro is active", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            } else {
                Section("Choose your plan") {
                    if purchases.products.isEmpty {
                        Text("Loading purchase options…")
                            .foregroundStyle(.secondary)
                        Button("Reload products") {
                            Task {
                                await purchases.load()
                            }
                        }
                    }
                    ForEach(purchases.products) { product in
                        Button {
                            Task {
                                await purchases.purchase(product)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(product.id == PurchaseStore.monthlyID ? "Monthly" : "Lifetime")
                                        .font(.headline)
                                    Text(product.id == PurchaseStore.monthlyID ? "Renews monthly. Cancel anytime." : "One purchase. No recurring charge.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(product.displayPrice + (product.id == PurchaseStore.monthlyID ? "/mo" : ""))
                                    .font(.headline)
                            }
                            .padding(.vertical, 8)
                        }
                        .disabled(purchases.isPurchasing)
                    }
                }
            }
            Section {
                Button("Restore Purchases") {
                    Task {
                        await purchases.restore()
                    }
                }
                .disabled(purchases.isPurchasing)
                Link("Manage subscriptions", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                NavigationLink("Privacy") {
                    PrivacyView()
                }
            } footer: {
                Text("Payment is charged to your Apple Account. Monthly subscriptions automatically renew unless canceled at least 24 hours before the current period ends. Manage or cancel in your App Store account settings. Lifetime unlocks the same Pro features without renewal. Buying lifetime does not cancel an existing subscription; cancel it in Manage subscriptions.")
            }
            if let message = purchases.message {
                Section {
                    Text(message)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("DevTools Pro")
        .onAppear {
            ads.isEditing = true
        }
        .onDisappear {
            ads.isEditing = false
        }
    }
}
