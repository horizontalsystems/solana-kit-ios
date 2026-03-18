# Review: 3.1 BalanceManager

## Build Status: FAILS

The project does not compile. There are 5 compilation errors across 3 files.

---

## Critical Issues

### 1. Protocols.swift missing `import Foundation` — causes 5 compilation errors

**Files:** `Protocols.swift:98`, `Protocols.swift:112`, `BalanceManager.swift:114`, `SyncManager.swift:99`

`Protocols.swift` only imports `Combine`, but the new `IBalanceManagerDelegate` and `ISyncManagerDelegate` protocols use `Decimal` (a Foundation type). The compiler cannot resolve `Decimal` in scope.

Errors:
```
Protocols.swift:98:  error: cannot find type 'Decimal' in scope
Protocols.swift:112: error: cannot find type 'Decimal' in scope
BalanceManager.swift:114: error: incorrect argument label in call (have 'balance:', expected 'balanceSyncState:')
BalanceManager.swift:114: error: cannot convert value of type 'Decimal' to expected argument type 'SyncState'
SyncManager.swift:99: error: no exact matches in call to instance method 'didUpdate'
```

The last three errors are cascading — because `didUpdate(balance: Decimal)` can't compile in the protocol, the compiler only sees `didUpdate(balanceSyncState: SyncState)`, causing label/type mismatch errors at call sites.

**Fix:** Add `import Foundation` to `Protocols.swift` (alongside existing `import Combine`).

### 2. Double emission on Combine subjects — balance and syncState published twice per update

**Files:** `BalanceManager.swift:113-114`, `Kit.swift:180-195`

Every balance change and sync state transition causes `balanceSubject.send()` and `syncStateSubject.send()` to be called **twice** with the same value. This happens because there are two parallel notification paths:

**Path 1 (direct):** `BalanceManager` sends to the injected subject directly:
```swift
// BalanceManager.swift:111-114
DispatchQueue.main.async { [weak self] in
    self.balanceSubject.send(value)              // <-- send #1
    self.delegate?.didUpdate(balance: value)     // triggers path 2
}
```

**Path 2 (delegate chain):** `BalanceManager` → delegate → `SyncManager` → delegate → `Kit`:
```swift
// Kit.swift:180-183
func didUpdate(balance: Decimal) {
    DispatchQueue.main.async { [weak self] in
        self?.balanceSubject.send(balance)       // <-- send #2 (same subject!)
    }
}
```

Since `balanceSubject` is the **same instance** (injected into BalanceManager during `Kit.instance()`), subscribers receive every value twice. `CurrentValueSubject` does not deduplicate.

The identical problem exists for `syncStateSubject`:
- Send #1: `BalanceManager.syncState.didSet` → `syncStateSubject.send(state)` (line 49)
- Send #2: delegate chain → `Kit.didUpdate(balanceSyncState:)` → `syncStateSubject.send(balanceSyncState)` (line 188)

**Impact:** Wallet UI subscribers will re-render twice per balance update. Could cause animation glitches or double side-effects in `sink` handlers.

**Fix — choose one path, not both:**

Option A — Remove the direct subject sends from `BalanceManager`. Let the delegate chain be the only path. BalanceManager would not need the injected subjects at all (only use delegates):
```swift
// In handleBalance:
if balance != newBalance {
    balance = newBalance
    try? storage.save(balance: lamports)
    delegate?.didUpdate(balance: newBalance)
}
syncState = .synced

// In syncState didSet:
delegate?.didUpdate(balanceSyncState: syncState)
```

Option B — Keep the direct subject sends in `BalanceManager`, but remove the subject sends from `Kit.didUpdate(balance:)` and `Kit.didUpdate(balanceSyncState:)` since the subject is already updated.

Option A is cleaner — it removes the subject injection from BalanceManager entirely, making the data flow unambiguous: BalanceManager → delegate → SyncManager → delegate → Kit → subjects.

---

## Minor Issues

### 3. No `CancellationError` filtering in `BalanceManager.sync()`

**File:** `BalanceManager.swift:94-95`

When the kit is stopped while a balance sync is in-flight, the Task may throw `CancellationError`. The catch block sets `syncState = .notSynced(error: CancellationError())`. This is harmless (the stop path via `SyncManager.didUpdateSyncerState(.notReady)` will override it) but could briefly flash an unexpected error through the publisher. `ApiSyncer.onFireTimer` already filters this (line 139); `BalanceManager` could do the same for consistency:
```swift
} catch {
    guard !(error is CancellationError) else { return }
    syncState = .notSynced(error: error)
}
```

### 4. Soft in-flight guard is not thread-safe

**File:** `BalanceManager.swift:87`

The `guard !syncState.syncing` check is not atomic. Two concurrent `sync()` calls (from rapid timer ticks) could both pass the guard before either sets `.syncing`. This matches the Android behavior exactly and is low-risk — the consequence is just a redundant RPC call. Not a bug per se, but worth noting.

---

## Architecture & Correctness: What's Good

- **Protocol-only dependencies:** BalanceManager depends on `IRpcApiProvider` and `IMainStorage` — no concrete types. Correct per architecture rules.
- **Delegate chain direction:** BalanceManager → SyncManager → Kit. No upward coupling. Weak delegates prevent retain cycles.
- **Init-time restore:** BalanceManager restores the last persisted balance in init, so `Kit.balance` has the correct value immediately after `Kit.instance()` returns.
- **Deduplication on persist:** Only writes to storage and notifies when the balance actually changes. Always transitions to `.synced` regardless.
- **Main queue dispatch:** All subject sends and delegate calls are dispatched on `DispatchQueue.main` per architecture rules.
- **SyncManager stop propagation:** `Kit.stop()` → `apiSyncer.stop()` → `.notReady` state → `SyncManager.didUpdateSyncerState` → `balanceManager.stop()`. Indirect but correct.
- **Lamports-to-SOL conversion:** `Decimal(lamports) / 1_000_000_000` using exact decimal arithmetic. No floating-point precision loss.
- **Protocols well-placed:** New delegate protocols in `Protocols.swift` follow the existing `IApiSyncerDelegate` naming pattern.

---

## Summary

| # | Severity | Issue | File(s) |
|---|----------|-------|---------|
| 1 | **Critical** | Missing `import Foundation` — build fails (5 errors) | `Protocols.swift` |
| 2 | **Medium** | Double emission on `balanceSubject` and `syncStateSubject` | `BalanceManager.swift`, `Kit.swift` |
| 3 | Minor | `CancellationError` not filtered in `sync()` catch | `BalanceManager.swift` |
| 4 | Minor | Soft in-flight guard (race on `syncState`) | `BalanceManager.swift` |

**Verdict:** Two issues must be fixed before merge — the build failure (#1) and the double emission (#2).
