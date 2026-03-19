## Code Review Summary

**Files Reviewed:** 8
- `Sources/SolanaKit/Transactions/TransactionSyncer.swift`
- `Sources/SolanaKit/Transactions/TransactionManager.swift`
- `Sources/SolanaKit/Transactions/PendingTransactionSyncer.swift`
- `Sources/SolanaKit/Core/SyncManager.swift`
- `Sources/SolanaKit/Core/Kit.swift`
- `Sources/SolanaKit/Core/Protocols.swift`
- `Sources/SolanaKit/Database/TransactionStorage.swift`
- All related model files (Transaction, TokenTransfer, MintAccount, TokenAccount, etc.)

**Risk Level:** :green_circle: Low

### Context Gates

- **Architecture** (`ARCHITECTURE.md`): WARN — Minor deviation: `TransactionManager` holds send logic (`sendSol`, `sendSpl`, `sendRawTransaction`) which adds significant coupling to infrastructure types (`SolanaSerializer`, `ComputeBudgetProgram`, `SystemProgram`, `TokenProgram`, `AssociatedTokenAccountProgram`). The architecture doc says "Core may call through protocol interfaces defined in Protocols.swift" and "Core must NOT import concrete types directly." `TransactionManager` calls these program helpers directly. Not blocking — these are pure utility types in `Helper/` and `Programs/`, but worth noting as the architecture envelope stretches here.
- **Rules** (`RULES.md`): No file found — WARN (non-blocking).
- **Roadmap** (`ROADMAP.md`): Milestone 3.4 is correctly marked `[x]` in the roadmap. Implementation aligns with the described scope.

### Critical Issues

None found. The implementation is correct, well-structured, and consistent with both the Android reference and the established iOS patterns.

### Suggestions

1. **Non-atomic sync guard in `TransactionSyncer.sync()` (line 91)**
   `TransactionSyncer.swift:91` — The guard `guard !syncState.syncing` followed by `syncState = .syncing(progress: nil)` is not atomic. Two concurrent `Task {}` blocks (e.g., from rapid `didUpdateLastBlockHeight` heartbeats) could both pass the guard before either sets the state to `.syncing`, causing duplicate sync work. This matches the Android pattern (which has the same race), and duplicate work is idempotent (DB upserts), so the impact is low — just wasted network calls. If tightening is desired, a simple `NSLock` or `os_unfair_lock` around the check-and-set would close the window.

2. **`LastSyncedTransaction` saved but never read back (`TransactionSyncer.swift:160-166`)**
   The sync cursor saved at step 12 (`storage.save(lastSyncedTransaction:)`) is never consumed by `TransactionSyncer`. The actual incremental cursor is `storage.lastNonPendingTransaction()?.hash` (line 186). The `LastSyncedTransaction` record appears to be dead write-only code within this syncer's scope. It matches the plan's specification (Task 6, step 12) and may serve future external consumers, but currently it's unreachable. Consider either removing it to reduce unnecessary DB writes, or adding a comment clarifying its purpose for future readers.

3. **Silent `try?` on storage persistence in `TransactionManager.handle()` (lines 188-190)**
   ```swift
   try? storage.save(transactions: mergedTransactions)
   try? storage.save(tokenTransfers: tokenTransfers)
   try? storage.save(mintAccounts: mintAccounts)
   ```
   If any persist call fails, the error is silently swallowed. The subsequent `storage.fullTransactions(hashes:)` call at line 193 will return stale/incomplete data, and consumers will receive a Combine event with partial results — with no indication that persistence failed. This matches the Android pattern (`try`-swallowed in Kotlin) but consider at minimum logging the error via `HsToolKit.Logger` for debuggability.

4. **Double `DispatchQueue.main.async` dispatch for transactions**
   `TransactionManager.handle()` dispatches `transactionsSubject.send()` on `DispatchQueue.main` (line 195). This flows to `SyncManager.transactionManagerCancellable` (already on main), which calls `Kit.didUpdate(transactions:)`, which dispatches on main *again* (Kit.swift:582). The double dispatch is harmless but adds an unnecessary extra main-queue hop. All other delegate callbacks go through a single main dispatch. Minor inconsistency.

### Positive Notes

- **Thorough merge logic**: `TransactionManager.handle()` correctly implements the pending-to-confirmed merge strategy, preserving existing fields (blockHash, lastValidBlockHeight, base64Encoded, retryCount) from DB records while updating with synced data. The cascade-delete via foreign keys on `TokenTransfer.transactionHash` ensures stale token transfers are cleaned up on transaction REPLACE.

- **Graceful degradation**: `resolveMintAccounts()` wraps the Metaplex fetch in `try?` and falls back to placeholder mint accounts with basic decimals info. This ensures transaction sync continues even when NFT metadata is unavailable.

- **Consistent patterns**: `TransactionSyncer` follows the exact same sync-state management pattern as `BalanceManager` and `TokenAccountManager` — `didSet` with `guard` against unchanged values, delegate notification on `DispatchQueue.main`, `stop(error:)` method. Code style is uniform across all three syncers.

- **Correct counterparty discovery**: `findCounterparty()` correctly handles both incoming (finds largest decrease) and outgoing (finds largest increase) directions, and correctly adjusts for fee-payer (index 0) when calculating the net SOL balance change.

- **Complete Kit wiring**: The factory method `Kit.instance()` correctly creates and wires all components, sets up delegate chains (`apiSyncer.delegate = syncManager`, `transactionSyncer.delegate = syncManager`, `syncManager.delegate = kit`), and subscribes to `transactionManager.transactionsPublisher` to trigger balance refresh on new transactions.

REVIEW_PASS
