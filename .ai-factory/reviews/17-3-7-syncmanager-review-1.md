# Review: 3.7 SyncManager

## Files reviewed
- `Sources/SolanaKit/Core/SyncManager.swift` (modified)
- `Sources/SolanaKit/Core/Kit.swift` (modified)

## Build status
Compiles successfully (iOS Simulator target). Only pre-existing Sendable warnings from `RpcApiProvider` — unrelated to this change.

## Changes summary
1. `transactionSyncer` and `transactionManager` promoted from optional post-init vars to required `private let` init parameters.
2. `didSet` subscription on `transactionManager` removed; replaced by explicit subscription in `start()`.
3. `start()`/`stop()`/`pause()`/`resume()` lifecycle methods added to SyncManager with `started` guard.
4. `Kit.swift` now routes lifecycle through SyncManager instead of directly calling ApiSyncer.
5. Factory updated to pass all five dependencies at construction; post-init injection removed.

## Correctness

### No issues found

**Init parameter promotion** — All optional chaining (`transactionSyncer?.sync()`, `transactionSyncer?.stop(error:)`, `transactionSyncer?.syncState`) correctly replaced with non-optional calls. The `?? .notSynced(error: SyncError.notStarted)` fallback in `transactionsSyncState` correctly removed since `transactionSyncer.syncState` already initializes to `.notSynced(error: SyncError.notStarted)`.

**start()** — Idempotent guard (`guard !started`) prevents double-subscription. `apiSyncer.start()` called before subscribing to transactions, which is correct since no transactions can arrive before the syncer is running. The Combine sink correctly matches the previous `didSet` behavior: triggers balance re-sync and forwards to delegate.

**stop()** — Calls `stop()` on all four subsystems (apiSyncer, balanceManager, tokenAccountManager, transactionSyncer), which correctly sets each subsystem's `syncState` to `.notSynced(error: SyncError.notStarted)`, propagating up through delegates. Cancellable set to `nil` to tear down subscription.

**stop() → start() restart** — After `stop()` sets `started = false`, a subsequent `start()` will pass the `guard !started` check and re-subscribe. `apiSyncer.start()` is also safe to call again since `apiSyncer.stop()` resets its `isStarted` flag. No state leak.

**Kit lifecycle routing** — `Kit.start()` calls `connectionManager.start()` before `syncManager.start()`. This is fine: `ConnectionManager.start()` initializes `NWPathMonitor`, and `syncManager.start()` → `apiSyncer.start()` → `handleUpdate(reachable: connectionManager.isConnected)`. Since `NWPathMonitor` hasn't fired its first update yet at this point, `isConnected` is still `false`, so ApiSyncer enters `.notReady(error: .noNetworkConnection)`. When the monitor then fires (on the next run loop), ApiSyncer picks it up via its Combine subscription and transitions to `.ready` + starts the timer. This is the correct startup sequence — matches Android behavior.

**Kit.stop()** — Calls `syncManager.stop()` before `connectionManager.stop()`. Correct order: syncer is torn down before the network monitor.

**Factory wiring** — SyncManager now receives all five deps at init. Delegate wiring happens after construction (as before). No ordering issue.

**refresh()** — Unchanged, still correct. In the `else` branch (`apiSyncer.stop()` then `apiSyncer.start()`), `stop()` resets `started` in ApiSyncer but not in SyncManager. This is correct — SyncManager's `started` flag tracks whether `SyncManager.start()` was called, not ApiSyncer's state. The ApiSyncer restart is a recovery mechanism.

### Minor observations (not blocking)

1. **No `transactionSyncer.stop()` call in `didUpdateSyncerState(.notReady)`** — The iOS code stops all three subsystems (balance, tokenAccount, transactionSyncer) when ApiSyncer goes not-ready. Android only stops balance and tokenAccount. This is a deliberate iOS-specific improvement and is consistent with the pre-existing behavior (just with `?` removed). Correct.

2. **`started` is not thread-safe** — `started` is a plain `Bool` read/written from potentially different threads (e.g., `start()` from main, `stop()` from main). In practice, all lifecycle methods are called from the main thread by Kit (which is the public API), so this is fine. The existing codebase doesn't use actors for managers.

3. **Kit retains `apiSyncer` property** — Kit still holds `private let apiSyncer: ApiSyncer` even though it no longer calls lifecycle methods on it directly. This is correct — the property keeps ApiSyncer alive (it would be deallocated otherwise since SyncManager holds it as a non-owning reference... actually SyncManager holds it as `private let`, so it does own it). Kit's reference is technically redundant but harmless and was intentionally kept per the plan ("keep the stored property since Kit.instance() creates it and it must stay alive"). In fact, SyncManager owns it now, so Kit's reference is just belt-and-suspenders. Not a bug.

## Security
No security concerns. No user input handling, no network surface changes.

## Race conditions
No new race conditions introduced. The transaction subscription sink dispatches a `Task` for `balanceManager.sync()` (async) and calls `delegate?.didUpdate(transactions:)` synchronously — same pattern as the previous `didSet` implementation. The delegate call chain into Kit dispatches onto `DispatchQueue.main`, matching the established pattern.

REVIEW_PASS
