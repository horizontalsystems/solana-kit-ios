# Plan: PendingTransactionSyncer

## Context
Monitor unconfirmed transactions by polling on each block-height heartbeat, re-broadcast the original base64-encoded signed transaction if its blockhash is still valid, and mark the transaction as failed when the blockhash expires. This is a direct port of Android `PendingTransactionSyncer.kt` following the existing iOS patterns established by `TransactionSyncer`, `BalanceManager`, and `SyncManager`.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Core syncer implementation

- [x] **Task 1: Create PendingTransactionSyncer class**
  Files: `Sources/SolanaKit/Transactions/PendingTransactionSyncer.swift`
  Create `PendingTransactionSyncer` as a `final class` in the `Transactions/` directory. Constructor takes `rpcApiProvider: IRpcApiProvider`, `storage: ITransactionStorage`, `transactionManager: TransactionManager` (same dependency pattern as `TransactionSyncer`). Implement `sync() async` with this logic (mirrors Android `PendingTransactionSyncer.sync()` lines 24-65):
  1. Call `storage.pendingTransactions()` to get all `pending == true` rows.
  2. If empty, return immediately.
  3. Call `rpcApiProvider.getBlockHeight()` to get current block height. If this throws, return immediately (no updates).
  4. For each pending transaction:
     - Try `rpcApiProvider.getTransaction(signature: pendingTx.hash)` — if it succeeds and response is non-nil, mark as confirmed: set `pending = false`, set `error` from the RPC response's error field (nil if success on-chain).
     - If `getTransaction` throws or returns nil: check `currentBlockHeight <= pendingTx.lastValidBlockHeight`. If true, call `resendTransaction(base64Encoded:)` (see Task 2), increment `retryCount`. If false, mark `pending = false` with `error = "BlockHash expired"`.
  5. Call `storage.updateTransactions(updatedTransactions)` to persist changes.
  6. Call `notifyUpdates(hashes:)` — fetch full transactions from storage via `storage.fullTransactions(hashes:)` and emit via `transactionManager` (see Task 3).
  Use `HsToolKit.Logger` for logging (same as `TransactionSyncer` uses), not `print`. Swallow individual per-transaction errors so one failure doesn't stop processing of remaining pending transactions.

- [x] **Task 2: Implement resendTransaction helper**
  Files: `Sources/SolanaKit/Transactions/PendingTransactionSyncer.swift`
  Add a `private func resendTransaction(base64Encoded: String) async` method to `PendingTransactionSyncer`. Call `rpcApiProvider.sendTransaction(serializedBase64: base64Encoded)` — the method already exists on `IRpcApiProvider`. Wrap in a do/catch and silently swallow errors (mirrors Android's empty catch block on `sendTransaction`). The Android version uses a hardcoded mainnet URL with raw `HttpURLConnection` — the iOS version should use the existing `IRpcApiProvider.sendTransaction` instead, which routes through the configured `RpcSource`. This is an intentional improvement over the Android code.

- [x] **Task 3: Add notifyTransactionsUpdate method to TransactionManager**
  Files: `Sources/SolanaKit/Transactions/TransactionManager.swift`
  Add a `func notifyTransactionsUpdate(_ transactions: [FullTransaction])` method to `TransactionManager`. This method sends the provided array through `transactionsSubject` on `DispatchQueue.main`, exactly like the existing `handle(...)` method does (line 111-113). This is the emission path for pending transaction status changes. Mirrors Android `TransactionManager.notifyTransactionsUpdate()` (line 111-113), which calls `_transactionsFlow.tryEmit(transactions)`.

### Phase 2: Wiring into the sync lifecycle

- [x] **Task 4: Wire PendingTransactionSyncer into TransactionSyncer**
  Files: `Sources/SolanaKit/Transactions/TransactionSyncer.swift`
  Add a `pendingTransactionSyncer: PendingTransactionSyncer` property to `TransactionSyncer`'s init. At the very beginning of `TransactionSyncer.sync()` (before the syncing guard and signature fetch), call `await pendingTransactionSyncer.sync()`. This mirrors Android `TransactionSyncer.sync()` line 69 where `pendingTransactionSyncer.sync()` is the first call. The pending sync must run on every heartbeat regardless of whether the main transaction sync is already in progress — so place the call **before** the `guard !syncState.syncing` check. This ensures pending transactions are polled even when the full history sync is mid-flight.

- [x] **Task 5: Instantiate and inject PendingTransactionSyncer in Kit.instance()**
  Files: `Sources/SolanaKit/Core/Kit.swift`
  In the `Kit.instance(...)` factory method, create `PendingTransactionSyncer(rpcApiProvider:storage:transactionManager:)` and pass it as a dependency to `TransactionSyncer`'s init (updated in Task 4). Follow the existing wiring pattern: `PendingTransactionSyncer` is created after `TransactionManager` and `TransactionStorage` (its two dependencies) but before `TransactionSyncer`. No new optional vars on `SyncManager` — `PendingTransactionSyncer` is owned by `TransactionSyncer`, not `SyncManager`. This mirrors the Android composition where `TransactionSyncer` holds `PendingTransactionSyncer` and calls it directly.
