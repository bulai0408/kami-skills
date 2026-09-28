import Foundation
import StoreKit

@MainActor
final class StoreManager: ObservableObject {
    static let proID = "com.acme.notes.pro.lifetime"
    static let monthlyID = "com.acme.notes.pro.monthly"

    @Published private(set) var isPro: Bool = UserDefaults.standard.bool(forKey: "isPro")
    @Published private(set) var products: [Product] = []

    private var tasks: [Task<Void, Never>] = []

    init() {
        tasks.append(Task { for await _ in Transaction.updates { await refresh() } })
        tasks.append(Task {
            for await _ in Storefront.updates {
                // storefront changed -> purchases from old region are invalid
                isPro = false
                UserDefaults.standard.set(false, forKey: "isPro")
                await loadProducts()
                await refresh()
            }
        })
        Task { await loadProducts(); await refresh() }
    }

    func loadProducts() async {
        products = (try? await Product.products(for: [Self.proID, Self.monthlyID])) ?? []
    }

    func refresh() async {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.revocationDate == nil { entitled = true }
        }
        isPro = entitled
        UserDefaults.standard.set(entitled, forKey: "isPro")
    }

    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }
}
