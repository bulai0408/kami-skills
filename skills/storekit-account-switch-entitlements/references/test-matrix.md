# Test matrix

Each row pins one invariant from SKILL.md §3. Drive the tests through the pure reconciliation function, or through the manager with an injected clock and a fake StoreKit source. Don't use real dates.

A useful check that the tests mean something: delete the retention branch and confirm that the "retained" rows go red.

## Unit tests

| # | Setup | Action | Expect |
|---|---|---|---|
| 1 | Lifetime purchase verified at T0 | Current account returns nothing at T0+1d | Pro on; notice `.retained(until: T0+30d)` |
| 2 | Same as 1 | Refresh again at T0+10d, still nothing | Deadline **still** T0+30d (retention doesn't extend) |
| 3 | Same as 1 | Refresh at T0+30d+1s | Pro off; notice `.expired` |
| 4 | Expired as in 3 | Relaunch app | Launch state is not optimistically unlocked (no unlock-then-lock flash); notice `.expired` |
| 5 | Expired as in 3 | Paying account returns a verified transaction at T1 | Pro on; notice nil; new deadline T1+30d |
| 6 | Monthly subscription, expires at E < T0+30d | Current account empty at T0+1d | Retained until **E**, not T0+30d; off after E |
| 7 | Snapshot has a purchase | Current account reports it **revoked** | Pro off immediately; entry removed from the snapshot; no notice |
| 8 | Snapshot entry is **family-shared** | Current account empty | Not retained; no notice |
| 9 | Snapshot has a monthly subscription | Current account has its **own** expired status for that product | Not retained; follow the current account |
| 10 | Never purchased on this device | Any refresh | Pro off; notice nil (no "switch back" message) |
| 11 | Retained state | Ask for a signed transaction for the server | nil; server features unavailable; local Pro still on |
| 12 | Valid snapshot saved | Keychain read fails (`unreadable`) during refresh | Snapshot bytes unchanged; state unchanged; next readable refresh retains normally |
| 13 | Verified at T0 | Clock set to T0−1d | Nothing retained |
| 14 | Retained state | `Transaction.updates` or purchase path returns empty | No state change until the next full refresh |
| 15 | Any state | `Storefront.updates` fires | A full refresh runs; nothing is cleared before it finishes |
| 16 | Snapshot owner appTransactionID = X | Current account also X, nothing entitled | Not retained; no "switch back" notice (same account: expiry/refund) |
| 17 | Retained / expired / normal | Render paywall + settings card | Retained shows the date and "switch back to renew"; expired shows "switch back to restore"; normal shows neither |
| 18 | Snapshot owner X | Current appTransactionID unavailable | Falls back to the other rules (retained if in window) |
| 19 | Snapshot entry from Sandbox (TestFlight) | Running App Store (Production) build, current account empty | Not retained |
| 20 | Monthly entry expired *and* window over | Refresh | Pro off; **no** "switch back" notice (nothing left to restore) |
| 21 | Valid snapshot in Keychain | Snapshot write fails mid-update | Previous snapshot still readable (update in place, never delete-then-add) |

## Sandbox walkthrough (real system behavior)

Run it on at least one platform. Record which platforms you ran and which you only inferred.

1. Start from a clean state: no snapshot, app shows the free tier.
2. Purchase with sandbox account **A**. Expect: verified, Pro on, no account-switch notice.
3. **Without relaunching**, sign sandbox account A out.
   - macOS: System Settings → [your name] → Media & Purchases (or App Store → Settings → Sandbox Account).
   - iOS/iPadOS: Settings → Developer → Sandbox Apple Account (older systems: Settings → App Store → Sandbox Account).
   - Expect: a storefront/account change triggers a refresh; logs show retention with deadline = verification time + window; the UI shows "kept until {date}"; paid features still work.
4. Optionally sign in sandbox account **B**, which has no purchases. Expect the same retained state. Restore Purchases finds nothing, so the UI must not suggest it.
5. Sign back into **A**. Expect silent renewal: verified state, notice gone, without tapping Restore.
6. Confirm user data is untouched: follow lists, settings, database integrity.

Things the sandbox can't show well, which you should state as unverified if you didn't test them: a storefront where your products don't exist (empty catalog with a retention banner on screen), and production-only refund timing.
