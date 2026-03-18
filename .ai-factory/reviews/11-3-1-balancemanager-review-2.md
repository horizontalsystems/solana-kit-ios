# Review: 3.1 BalanceManager (round 2)

## Build Status: PASSES

`xcodebuild -scheme SolanaKit` compiles cleanly with zero errors and zero warnings.

---

## Review-1 Fixes Verified

All three issues from review-1 have been addressed:

1. **`import Foundation` added to `Protocols.swift`** (line 9) — resolves all 5 compilation errors. Verified: `Decimal` is now in scope for both `IBalanceManagerDelegate` and `ISyncManagerDelegate`.

2. **Double emission eliminated.** `BalanceManager` no longer holds or sends to Combine subjects. It only notifies via the delegate chain: `BalanceManager` → `SyncManager` → `Kit` → subjects. There is now exactly one `send()` per value change on each subject. Verified by tracing:
   - Balance path: `handleBalance` → `DispatchQueue.main.async { delegate?.didUpdate(balance:) }` → `SyncManager` forwards → `Kit.didUpdate(balance:)` → `DispatchQueue.main.async { balanceSubject.send() }`
   - SyncState path: `syncState.didSet` → `DispatchQueue.main.async { delegate?.didUpdate(balanceSyncState:) }` → `SyncManager` forwards → `Kit.didUpdate(balanceSyncState:)` → `DispatchQueue.main.async { syncStateSubject.send() }`

3. **`CancellationError` filtering added** (`BalanceManager.swift:79`) — `sync()` now returns silently on cancellation instead of setting `.notSynced(error: CancellationError)`, consistent with `ApiSyncer.onFireTimer`.

---

## Data Flow Trace (end-to-end)

Verified the complete path from timer tick to subscriber:

```
ApiSyncer.onFireTimer (Task, background thread)
  → getBlockHeight() via RPC
  → handleBlockHeight(_:)
    → delegate?.didUpdateLastBlockHeight(_:)                    [background thread]
      → SyncManager.didUpdateLastBlockHeight
        → Kit.didUpdate(lastBlockHeight:)
          → DispatchQueue.main.async { lastBlockHeightSubject.send() }
        → Task { balanceManager.sync() }
          → getBalance() via RPC
          → handleBalance(_:)
            → if changed: DispatchQueue.main.async { delegate?.didUpdate(balance:) }
              → SyncManager → Kit → DispatchQueue.main.async { balanceSubject.send() }
            → syncState = .synced → didSet
              → DispatchQueue.main.async { delegate?.didUpdate(balanceSyncState:) }
                → SyncManager → Kit → DispatchQueue.main.async { syncStateSubject.send() }
```

All subject `.send()` calls arrive on `DispatchQueue.main`. Correct.

---

## Correctness Checks

- **Init-time restore**: `BalanceManager.init` reads `storage.balance()`, sets `self.balance`. `Kit.instance()` then seeds `balanceSubject` with `balanceManager.balance ?? 0`. Correct — consumers see the persisted balance immediately.
- **Deduplication**: `handleBalance` only notifies delegate when `balance != newBalance`. Optional comparison (`nil != Decimal`) correctly triggers on first sync. Subsequent syncs with unchanged balance skip notification but still set `.synced`.
- **Retain cycles**: Kit → (strong) SyncManager → (strong) BalanceManager. SyncManager.delegate → (weak) Kit. BalanceManager.delegate → (weak) SyncManager. ApiSyncer.delegate → (weak) SyncManager. No cycles.
- **Stop propagation**: `Kit.stop()` → `apiSyncer.stop()` → state `.notReady` → `SyncManager.didUpdateSyncerState(.notReady)` → `balanceManager.stop()` → syncState `.notSynced`. Indirect but complete.
- **Lamports conversion**: `Decimal(lamports) / 1_000_000_000` — exact decimal arithmetic, no floating-point precision loss.
- **Protocol-only dependencies**: `BalanceManager` depends on `IRpcApiProvider` and `IMainStorage` — no concrete types imported. Correct per architecture rules.
- **Refresh**: `SyncManager.refresh()` either triggers a direct `sync()` when API is ready, or restarts the polling loop. Both paths correctly result in a balance sync.

---

## Minor Notes (not blocking)

1. **Soft in-flight guard** (`BalanceManager.swift:71`): The `!syncState.syncing` check is not atomic — two concurrent Tasks could pass it simultaneously. Matches Android. Consequence is at worst a redundant RPC call.

2. **In-flight Task not cancelled on stop**: When `Kit.stop()` is called while `balanceManager.sync()` is awaiting `getBalance`, the RPC call will complete and `handleBalance` may briefly set `.synced` after stop already set `.notSynced`. This is the same accepted trade-off as Android and EvmKit — no observer should be listening after stop.

3. **Double main-queue hop for balance/syncState**: BalanceManager dispatches delegate calls to main queue, then Kit dispatches to main queue again (one extra run-loop iteration). Functionally correct — just minor latency. Kit's defensive dispatch is appropriate since `lastBlockHeight` arrives from a background thread via the same delegate interface.

---

## Summary

| # | Severity | Status |
|---|----------|--------|
| 1 | ~~Critical~~ | Fixed — `import Foundation` added |
| 2 | ~~Medium~~ | Fixed — single notification path via delegates |
| 3 | ~~Minor~~ | Fixed — `CancellationError` filtered |
| 4 | Minor | Noted — soft in-flight guard, matches Android |

No critical or medium issues remain. Code compiles, data flow is correct, architecture rules are followed.

REVIEW_PASS
