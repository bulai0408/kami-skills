# Reference implementation (Swift, StoreKit 2)

This is a platform-neutral sketch of bounded retention: the snapshot, the pure reconciliation step, and the wiring into a refresh. It is based on a pattern that has shipped in production. Adapt the names to your code. Keep the reconciliation step a pure function, because that's what makes every rule in SKILL.md §3 unit-testable with an injected clock.

## Contents
- Snapshot model
- Keychain storage (read error ≠ absent)
- Pure reconciliation
- Wiring into the entitlement manager
- Notes

## Snapshot model

```swift
import Foundation
import StoreKit

/// Minimal, non-sensitive summary of transactions StoreKit verified on the paying account.
/// No JWS and no transaction IDs: it can't serve as proof of purchase anywhere else.
struct EntitlementSnapshot: Codable, Equatable {
    static let retentionWindow: TimeInterval = 30 * 24 * 60 * 60

    struct Entry: Codable, Equatable {
        let productID: String
        let purchaseDate: Date
        let expirationDate: Date?              // nil for non-consumables
        let gracePeriodExpirationDate: Date?
        let isFamilyShared: Bool
        let environment: String                 // Transaction.environment.rawValue
    }

    let verifiedAt: Date                        // refreshed ONLY by a fresh verification
    let entries: [Entry]
    var ownerAppTransactionID: String? = nil    // AppTransaction.appTransactionID of the paying account

    var retentionDeadline: Date { verifiedAt.addingTimeInterval(Self.retentionWindow) }

    /// Entries the user still paid for at `now` (subscriptions capped by expiry or grace).
    func stillPaidFor(now: Date) -> [Entry] {
        guard now >= verifiedAt else { return [] }          // clock rollback grants nothing
        return entries.filter { entry in
            guard let expiry = entry.expirationDate else { return true }
            return now < max(expiry, entry.gracePeriodExpirationDate ?? expiry)
        }
    }

    /// What retention may honor: own purchases, inside the window.
    func retainable(now: Date) -> [Entry] {
        guard now < retentionDeadline else { return [] }
        return stillPaidFor(now: now).filter { !$0.isFamilyShared }
    }
}

extension EntitlementSnapshot.Entry {
    init(_ t: Transaction, graceEnd: Date?) {
        self.init(productID: t.productID, purchaseDate: t.purchaseDate,
                  expirationDate: t.expirationDate, gracePeriodExpirationDate: graceEnd,
                  isFamilyShared: t.ownershipType == .familyShared,
                  environment: t.environment.rawValue)
    }
}
```

## Keychain storage (read error ≠ absent)

```swift
enum SnapshotRead { case absent, value(EntitlementSnapshot), unreadable }

struct SnapshotStore {
    let service = "com.example.app.entitlement-snapshot"

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "snapshot",
         kSecUseDataProtectionKeychain as String: true,   // macOS: use the iOS-style keychain
         kSecAttrSynchronizable as String: false]         // never iCloud-sync a purchase
    }

    func read() -> SnapshotRead {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &out) {
        case errSecSuccess:
            guard let data = out as? Data,
                  let snap = try? JSONDecoder().decode(EntitlementSnapshot.self, from: data) else { return .absent }
            return .value(snap)
        case errSecItemNotFound:
            return .absent
        default:
            // e.g. errSecInteractionNotAllowed during a locked-device background launch.
            // The caller must not overwrite or re-judge on this result.
            return .unreadable
        }
    }

    func write(_ snapshot: EntitlementSnapshot?) {
        guard let snapshot else { SecItemDelete(baseQuery as CFDictionary); return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // Update in place; never delete-then-add, or a failed add erases a valid snapshot.
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
```

`AfterFirstUnlockThisDeviceOnly` makes background refreshes after the first unlock able to read the snapshot. `ThisDeviceOnly` keeps it out of backups restored onto other devices. Even with this class, keep the `.unreadable` branch: a background launch before the first unlock still fails.

## Pure reconciliation

```swift
/// What the *current* account told us during a full refresh.
struct AccountEvidence {
    var revokedProductIDs: Set<String>            // StoreKit reported a revocation
    var productsWithOwnSubscriptionStatus: Set<String>  // current account has its own status
    var currentAppTransactionID: String? = nil          // nil = unknown (offline / unverified)
    var currentEnvironment: String? = nil               // AppTransaction.environment.rawValue; nil = unknown
}

enum AccountSwitchNotice: Equatable {
    case retained(until: Date)                    // show "kept until {date}, switch back to renew"
    case expired                                  // show "switch back to restore" (verified purchasers only)
}

struct Reconciliation {
    var snapshotToStore: EntitlementSnapshot?     // nil = delete
    var retainedEntries: [EntitlementSnapshot.Entry]
    var notice: AccountSwitchNotice?
}

func reconcile(current: EntitlementSnapshot?,
               freshlyVerified: [EntitlementSnapshot.Entry],   // active, verified, from this refresh
               evidence: AccountEvidence,
               now: Date) -> Reconciliation {
    // Paying account is back (or never left): this is the ONLY place verifiedAt moves.
    if !freshlyVerified.isEmpty {
        return .init(snapshotToStore: .init(verifiedAt: now, entries: freshlyVerified,
                                            ownerAppTransactionID: evidence.currentAppTransactionID),
                     retainedEntries: [], notice: nil)
    }
    guard let current else { return .init(snapshotToStore: nil, retainedEntries: [], notice: nil) }

    // Same Apple Account as the purchaser, yet nothing is entitled: not an account switch
    // (expiry, refund, or a bug) — retention does not apply. Unknown IDs fall through.
    if let owner = current.ownerAppTransactionID, let currentID = evidence.currentAppTransactionID, owner == currentID {
        return .init(snapshotToStore: nil, retainedEntries: [], notice: nil)
    }

    // Current-account evidence beats the snapshot; family sharing is never retained.
    let pruned = EntitlementSnapshot(verifiedAt: current.verifiedAt, entries: current.entries.filter {
        !$0.isFamilyShared
            && !evidence.revokedProductIDs.contains($0.productID)
            && !evidence.productsWithOwnSubscriptionStatus.contains($0.productID)
            // A sandbox/TestFlight purchase must not carry into a production build, or vice versa.
            && (evidence.currentEnvironment == nil || $0.environment == evidence.currentEnvironment)
    }, ownerAppTransactionID: current.ownerAppTransactionID)

    let retained = pruned.retainable(now: now)
    guard !retained.isEmpty else {
        // Window over: keep the pruned snapshot as a marker. Say "switch back" only if something is
        // still paid for — a lapsed subscription can't be restored by switching accounts.
        return .init(snapshotToStore: pruned, retainedEntries: [],
                     notice: pruned.stillPaidFor(now: now).isEmpty ? nil : .expired)
    }
    let until = retained.map { entry -> Date in
        let paidUntil = entry.gracePeriodExpirationDate ?? entry.expirationDate ?? .distantFuture
        return min(paidUntil, pruned.retentionDeadline)
    }.max()!
    return .init(snapshotToStore: pruned, retainedEntries: retained, notice: .retained(until: until))
}
```

## Wiring into the entitlement manager

```swift
@MainActor @Observable
final class EntitlementManager {
    static let productIDs = ["com.example.app.lifetime", "com.example.app.monthly"]
    private(set) var isPro = false
    private(set) var accountSwitchNotice: AccountSwitchNotice?
    private let store = SnapshotStore()
    private var snapshot: EntitlementSnapshot?
    private var snapshotReadable = true
    private var boundaryTask: Task<Void, Never>?

    init() {
        switch store.read() {
        case .value(let s):
            snapshot = s
            // Optimistic launch state only while inside the window; otherwise wait for StoreKit.
            if Date.now < s.retentionDeadline, !s.stillPaidFor(now: .now).isEmpty { isPro = true }
        case .absent: break
        case .unreadable: snapshotReadable = false
        }
        Task { for await _ in Storefront.updates { await fullRefresh() } }       // re-run, never clear
        Task { for await _ in Transaction.updates { await fullRefresh() } }      // don't rule on partials
    }

    /// Call at launch, on foreground, after purchase/restore, on storefront and transaction updates.
    func fullRefresh() async {
        let now = Date.now
        var fresh: [EntitlementSnapshot.Entry] = []
        var evidence = AccountEvidence(revokedProductIDs: [], productsWithOwnSubscriptionStatus: [])

        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }        // unverified never grants
            if t.revocationDate != nil { evidence.revokedProductIDs.insert(t.productID); continue }
            fresh.append(.init(t, graceEnd: nil))                         // fill graceEnd from status
        }
        if case .verified(let app)? = try? await AppTransaction.shared {
            evidence.currentAppTransactionID = app.appTransactionID   // don't block on failure
            evidence.currentEnvironment = app.environment.rawValue
        }
        // currentEntitlements omits refunded/revoked transactions, so ask latest(for:) explicitly.
        for productID in Self.productIDs {
            if case .verified(let t)? = await Transaction.latest(for: productID), t.revocationDate != nil {
                evidence.revokedProductIDs.insert(productID)
            }
        }
        // For subscriptions, also read Product.SubscriptionInfo.status: add the product to
        // productsWithOwnSubscriptionStatus when the current account has any status for it, and
        // take the grace-period end from the renewal info.

        if fresh.isEmpty, !snapshotReadable {
            if case .value(let s) = store.read() { snapshot = s; snapshotReadable = true }
            else if case .absent = store.read() { snapshotReadable = true }
        }
        // Unreadable and nothing fresh: keep the current state, don't overwrite or re-judge.
        guard !fresh.isEmpty || snapshotReadable else { return }

        let r = reconcile(current: snapshot, freshlyVerified: fresh, evidence: evidence, now: now)
        if r.snapshotToStore != snapshot { store.write(r.snapshotToStore); snapshot = r.snapshotToStore }
        snapshotReadable = true
        isPro = !fresh.isEmpty || !r.retainedEntries.isEmpty
        accountSwitchNotice = r.notice
        scheduleNextBoundary(now: now)
    }

    private func scheduleNextBoundary(now: Date) {
        boundaryTask?.cancel()
        let boundaries = (snapshot?.entries ?? []).flatMap { [$0.expirationDate, $0.gracePeriodExpirationDate] }
            .compactMap { $0 } + [snapshot?.retentionDeadline].compactMap { $0 }
        guard let next = boundaries.filter({ $0 > now }).min() else { return }
        boundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now)))
            guard !Task.isCancelled else { return }
            await self?.fullRefresh()
        }
    }
}
```

## Notes

- **Inject the clock** (`now`) everywhere instead of calling `Date.now` inside the rules. Every invariant is time-based, and without injection none of them are testable.
- **Server features during retention.** When access comes from retention you have no `Transaction.jwsRepresentation` for the current account. Return `nil` from whatever hands a signed transaction to your server, and surface that state in the UI.
- **Diagnostics.** Expose `accountSwitchNotice` in your diagnostics export. It's the fastest way for support to tell "switched accounts" from "real bug".
- **Mixed accounts (known limitation of this sketch).** A fresh verification replaces the whole snapshot. If a user has a lifetime unlock on account A and a subscription on account B, verifying on B forgets A's lifetime entry. They're still Pro through B, but if they cancel B they must switch back to A once. Merging per-entry `verifiedAt` fixes this at the cost of more rules. Most apps can accept the simpler version.
- **Multiple products.** The sketch treats every entry the same. If a lifetime unlock and a subscription can coexist, apply the evidence rules per product: a revoked lifetime purchase shouldn't drop an active subscription, and the reverse holds too.
