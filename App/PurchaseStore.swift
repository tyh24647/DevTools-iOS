import Combine
import Foundation
import StoreKit

/// Premium access is derived solely from verified StoreKit 2 transactions, including revocations
/// and subscription expiry. The App Group snapshot makes the result available to Safari offline.
@MainActor
final class PurchaseStore: ObservableObject {
    static let monthlyID = "com.tyh24647.DevTools.pro.monthly"
    static let lifetimeID = "com.tyh24647.DevTools.pro.lifetime"
    @Published private(set) var products: [Product] = []
    @Published private(set) var isPurchasing = false
    @Published var message: String?
    private var listener: Task<Void, Never>?
    var onChange: (() -> Void)?

    init() {
        listener = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else {
                    return
                }
                if case .verified(let transaction) = result {
                    await self.refreshEntitlements()
                    await transaction.finish()
                }
            }
        }
    }

    deinit {
        listener?.cancel()
    }

    func load() async {
        do {
            products = try await Product.products(for: [Self.monthlyID, Self.lifetimeID]).sorted {
                $0.price < $1.price
            }
            if products.isEmpty {
                message = "Products are unavailable. In Xcode select the included DevTools.storekit configuration, or configure these products in App Store Connect."
            }
        } catch {
            message = error.localizedDescription
        }
        await refreshEntitlements()
    }

    func purchase(_ product: Product) async {
        guard !isPurchasing else {
            return
        }
        isPurchasing = true
        defer {
            isPurchasing = false
        }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(.verified(let transaction)):
                await refreshEntitlements()
                await transaction.finish()
                message = "DevTools Pro is unlocked. Reload Safari pages to activate plugins."
            case .success(.unverified(_, _)):
                message = "The App Store transaction could not be verified."
            case .pending:
                message = "Your purchase is awaiting approval."
            case .userCancelled:
                break
            @unknown default:
                message = "Unknown App Store response. Try Restore Purchases."
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            let active = (try? SharedStore.shared.read().entitlement.isPro) ?? false
            message = active ? "Purchases restored." : "No active Pro purchase was found."
        } catch {
            message = error.localizedDescription
        }
    }

    func refreshEntitlements() async {
        var snapshot = EntitlementSnapshot()
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil, !transaction.isUpgraded else {
                continue
            }
            if transaction.productID == Self.lifetimeID {
                snapshot.lifetime = true
            } else if transaction.productID == Self.monthlyID,
                      let expiry = transaction.expirationDate, expiry > Date() {
                snapshot.subscriptionExpiresAt = max(snapshot.subscriptionExpiresAt ?? 0, expiry.timeIntervalSince1970)
            }
        }
        snapshot.verifiedAt = Date().timeIntervalSince1970
        do {
            let current = try SharedStore.shared.read().entitlement
            if current.lifetime != snapshot.lifetime || current.subscriptionExpiresAt != snapshot.subscriptionExpiresAt {
                try SharedStore.shared.update {
                    $0.entitlement = snapshot
                }
            }
            onChange?()
        } catch {
            message = error.localizedDescription
        }
    }
}
