---
name: storekit-account-switch-entitlements
description: Keep StoreKit 2 in-app purchase entitlements from disappearing when users switch App Store accounts or regions (storefronts) on iOS, iPadOS, macOS, tvOS or visionOS. Covers why it happens, how to tell a region change from an account switch, the policy options, and a production-tested bounded on-device retention pattern with its invariants, user-facing copy and test matrix. Use this whenever a user reports "lost my purchase / Pro after switching Apple ID or region", "restore purchases doesn't work", 换区掉权益 / 切换 Apple ID 后权益没了 / 外区买的国区用不了, or when designing, implementing or reviewing StoreKit 2 entitlement caching, offline grace, `Transaction.currentEntitlements`, `AppStore.sync()` or `Storefront.updates` handling — even if account switching is not named explicitly.
---

# Keeping entitlements across App Store account and region switches

A StoreKit 2 app that answers "is this user entitled?" purely from `Transaction.currentEntitlements` will lock paying users out the moment they sign into a different App Store account. In some markets that happens every day: users buy in one storefront (because the app or price is only available there) and then switch back to their home account for everything else. To them it looks like the app stole their purchase, and **Restore Purchases can't help**.

This skill gives you the mental model, the decision, and a pattern that has shipped in a commercial app on all four Apple platforms.

Size the answer to the question. A quick design question needs the conclusion and the few invariants that matter to it. A fix or a review needs the full treatment.

## 1. The mental model

A purchase belongs to **the Apple Account that paid for it**. It does not belong to the device or the storefront.

- `Transaction.currentEntitlements`, `Transaction.latest(for:)` and `Product.SubscriptionInfo.status` answer for **the account currently signed into the App Store**.
- `AppStore.sync()` (Restore Purchases) syncs **the current account's** transactions. It can't bring in another account's purchases.
- `Storefront.updates` fires when the storefront changes. That happens both when the same account changes region and when a different account signs in. The event alone doesn't tell you which.

Two different user actions both get called "switching region" (换区). Work out which one you're dealing with before you design anything:

| What the user did | What StoreKit reports | What it means for you |
|---|---|---|
| **A. Same Apple Account, changed country/region** | Transactions stay on the account. Products, prices and availability change. | Mostly a *catalog* problem: refetch `Product`s. If entitlements disappear here, suspect your own code first (for example, gating on `Storefront.countryCode`, or treating a storefront change as "clear entitlements"). |
| **B. Signed into a different Apple Account** (for example, bought on a US account, switched back to a CN account) | No transactions. `currentEntitlements` is empty; `sync()` finds nothing. | This is the real "lost my purchase" case. You need an explicit policy. |

When you triage a report, ask: *"Did you sign out of one Apple Account and into another, or change the region of the same account?"* On macOS the signed-in account is in App Store → Settings; on iOS it's in Settings → [name] → Media & Purchases.

**The app can also tell the two cases apart itself.** `AppTransaction.shared` → `appTransactionID` (iOS 16 / macOS 13 / tvOS 16+) is globally unique per Apple Account that downloaded the app, and it stays the same across storefront changes, redownloads and refunds. Record it next to your verified snapshot:

- **Same ID, but entitlements are now missing:** it's the same account. This isn't an account switch, so don't retain. It's an expiry, a refund, or a bug in your code.
- **Different ID:** the user switched accounts (case B), so retention applies.
- **Unavailable** (offline, verification failed): treat it as "unknown". Fall back to the rules in §3, and never block the decision waiting for it.

Each Family Sharing member gets their own ID. That doesn't matter here, because family-shared access is never retained anyway.

## 2. Pick a policy

There are three coherent choices. Choose one on purpose and write it down (ADR, design doc). Entitlement bugs are expensive, and this is a trade-off, not a fix.

1. **Strict: StoreKit is the only truth.** Lock as soon as the current account has no verified transaction. Simplest and impossible to abuse. The cost is that case-B users lose access every time they switch, and support tickets follow. Pick this only if your users rarely switch accounts.
2. **Bounded on-device retention (recommended default).** Keep a verified snapshot on the device. When the current account shows nothing, keep honoring the *user's own* purchase for a limited window measured from the last time the paying account verified it. Needs no backend and no login. Privacy is unchanged if the snapshot stays on-device. Abuse is bounded by the window. §3 covers it in full.
3. **Your own account system + server.** Tie purchases to your user ID (`appAccountToken` at purchase time, App Store Server API / Server Notifications V2 on the backend) and grant from your server. This is the only option that survives indefinitely across accounts, but it means login, a backend, privacy-policy changes and more review surface. It is worth it only if you already have accounts. Existing buyers can link a past purchase without switching Apple Accounts: they paste the order ID from Apple's receipt email, your server resolves it with the App Store Server API's *Look Up Order ID* endpoint, and you limit each purchase to one of your accounts.

Separately, if you *can* sell in the users' home storefront, do it. New buyers then purchase on the account they actually use, and the problem stops growing. Some storefronts have extra requirements. The China mainland, for example, requires a filing number in App Store Connect. Check the current rules.

Don't invent a fourth option that trusts an unbounded local flag (a `UserDefaults` bool, a non-expiring cache). That's an infinite free unlock, and refunds never revoke it.

## 3. Bounded retention: the invariants

Every rule below exists because a simpler version failed in a specific way. Keep the reasons with the rules. If you drop one, you reopen the hole it closes.

### What gets stored

1. **Write the snapshot only from verified StoreKit results.** Store product ID, purchase date, expiration date, grace-period expiration, ownership type and a `verifiedAt` timestamp. You don't need JWS or transaction IDs. Leaving them out keeps the snapshot from becoming sensitive data, and it keeps the design honest: the snapshot can't be sent anywhere as proof of purchase.
2. **Keep it in the Keychain: data-protection keychain, this device only, not iCloud-synced.** A `UserDefaults` value is trivially editable. Syncing it through iCloud would spread one account's purchase to every device on a different Apple Account.

### How long it lasts

3. **Only a fresh verification on the paying account refreshes `verifiedAt`.** Retaining must never extend the window, or the bound stops meaning anything.
4. **The window is fixed (for example, 30 days), measured from `verifiedAt`.** A subscription is additionally capped by the expiration or grace date recorded in the snapshot. Retention never outlives what the user actually paid for.
5. **Clock rollback grants nothing.** If `now < verifiedAt`, retain nothing.

### Who qualifies

6. **Retain only `ownershipType == .purchased`.** Family-shared access comes through the organizer's account and the family relationship can end, so never retain it.
7. **Evidence from the current account always wins over the snapshot.**
   - If StoreKit reports the product as **revoked** (refund, chargeback), lock immediately and remove that entry from the snapshot.
   - If the current account has its **own** subscription status for that product (for example, its own expired subscription), follow it. Don't retain the snapshot's subscription.

### When to decide

8. **Apply retention only at the end of a full refresh** (current entitlements + latest + subscription statuses) that came back absent or unverified. Purchase results, `Transaction.updates` callbacks and other partial paths can see an empty result for unrelated reasons. Let them defer to the next full refresh instead of ruling on their own.
9. **Treat "unreadable" differently from "absent".** On iOS, a background launch while the device is locked can make Keychain reads fail (`errSecInteractionNotAllowed` with the default `WhenUnlocked` accessibility). If you treat that as "no snapshot", you overwrite a valid snapshot with nothing and lock a paying user out. On a read error, don't overwrite and don't re-judge. Keep the current state, retry on the next refresh, or choose an `AfterFirstUnlock…` accessibility class on purpose.
10. **Treat `Storefront.updates` as "re-run the full refresh"** (products and entitlements). Never treat it as "clear entitlements". Don't depend on it alone to catch account switches, either: two accounts in the same storefront produce no storefront change. Also run the full refresh at launch and every time the app returns to the foreground.

### Lifecycle

11. **At launch, show the snapshot optimistically only while it's inside its window.** An expired snapshot shown as unlocked produces an unlock-then-lock flash once StoreKit answers.
12. **Schedule a refresh at the next boundary:** the retention deadline, a subscription expiration or a grace-period end. Access then ends on time without waiting for a relaunch.
13. **Be explicit about what retention can't do.** During retention there's no signed transaction to show a server, so server-validated features (cloud features, referral credit, anything that uploads a JWS) stay unavailable. Show that state honestly. Don't fake it.

`references/reference-implementation.md` has a platform-neutral Swift sketch of the snapshot and reconciliation step that encodes these rules.

## 4. Tell the user what's happening

Retention without an explanation is confusing: the app works today and locks in a month for no visible reason. The only action that actually fixes it is **switching back to the paying Apple Account and opening the app**. Say exactly that.

- **During retention** (paywall header, settings/license card): *"No purchase was found for the current App Store account. Pro stays available until {date}. Switch back to the Apple Account you purchased with and open the app to renew."*
- **After the window**, show this only to users this device has verified as purchasers: *"No purchase was found for the current App Store account. Switch back to the Apple Account you purchased with, and open the app to restore Pro."*
- **Never** show account-switch messaging to someone who never purchased on this device. For them it's noise, or a hint to go looking for a purchase that doesn't exist.
- **Don't route these users into Restore Purchases** as the fix. It syncs only the current account, so it fails, and a failed restore reads as "the app is broken".
- Match the tone of your existing copy. Give the date. Don't apologize at length.

**Support replies, before any app update ships:** the user only has to switch the **Media & Purchases** account (Settings → [name] → Media & Purchases on iOS; App Store → Settings on macOS). Their iCloud account can stay as it is. After switching, they open the app once. With retention in place, that also restarts the window. Put this in a help page and in replies to reviews.

Add a line to your diagnostics export (for example, `accountSwitchRetention: retained until 2026-10-23` / `expired` / none). Support can then tell this case from a real bug in one glance.

## 5. Ship it responsibly

- **State the cost in the decision record.** A user who refunds on account X and switches to account Y keeps access for up to the window. It isn't a lasting exploit: using the app on account X again shows the revocation and locks immediately.
- **Check the privacy policy.** Nothing new leaves the device if the snapshot stays local. If you add server checks later, revisit.
- **Mention migration in the release notes.** Users whose snapshot an older build already cleared get nothing to retain. They need to open the new version once on the paying account before the window applies.
- **Watch for paywall conflicts.** In a storefront where your products don't exist, the product list is empty. Make sure the "store unavailable" state and the retention banner don't contradict each other on the same screen.

## 6. Verify with real behavior

Unit tests pin the rules, but only a real account switch proves the integration. Use `references/test-matrix.md`. It has the unit-test cases, one per invariant, and a sandbox walkthrough: buy with a sandbox account, sign it out without relaunching, confirm the retained state and date, then sign back in and confirm silent renewal without Restore. Run the walkthrough on at least one platform, and note which platforms you didn't run.

## When reviewing existing entitlement code

Check for these, most damaging first:

1. Does a storefront change or an empty `currentEntitlements` wipe a cached unlock with no bound or reason? (Case-B lockout.)
2. Does any local state grant access **without** a bound or a revocation check? (Infinite unlock.)
3. Does anything other than a fresh owner-account verification extend the window?
4. Are family-shared transactions retained?
5. Does a Keychain read error get treated as "no snapshot"?
6. Do partial refresh paths (purchase, `Transaction.updates`) make the final call?
7. Does the UI send the user to Restore Purchases for a problem Restore can't solve?

The same review usually turns up these related problems, which are worth reporting too:
- the entitlement check doesn't filter by product ID, so a future tip jar would unlock Pro;
- `Transaction.updates` never calls `finish()`;
- there's no refresh on foreground or at subscription expiry;
- overlapping refreshes can finish in any order, and the last one to finish wins;
- `try?` swallows errors in product loading and restore, so "not sold in this storefront" and "nothing found" look like a broken app.
