# Review: 3.5 PendingTransactionSyncer

## Files Reviewed

| File | Status |
|------|--------|
| `Sources/SolanaKit/Transactions/PendingTransactionSyncer.swift` | New (142 lines) |
| `Sources/SolanaKit/Transactions/TransactionManager.swift` | Modified (+11 lines) |
| `Sources/SolanaKit/Transactions/TransactionSyncer.swift` | Modified (+8 lines) |
| `Sources/SolanaKit/Core/Kit.swift` | Modified (+8 lines) |

## Build

iOS Simulator build: **PASSED** (xcodebuild, iPhone 17 / iOS 26.1).

## Correctness

### PendingTransactionSyncer.swift

**Logic matches Android reference.** The three-way branch (confirmed / blockhash-valid / blockhash-expired) at lines 66-115 is a faithful port of Android `PendingTransactionSyncer.sync()` lines 34-61. Differences are intentional improvements:
- Uses `IRpcApiProvider.sendTransaction` instead of Android's hardcoded mainnet `HttpURLConnection`.
- Uses `getTransaction` (which wraps `getTransaction` RPC) instead of Android's deprecated `getConfirmedTransaction`.

**Type safety verified:**
- `currentBlockHeight` is `Int64`, `pendingTx.lastValidBlockHeight` is `Int64` — comparison at line 82 is type-safe.
- `response.meta?.err?.description` — `err` is `AnyCodable?` which conforms to `CustomStringConvertible`, so `.description` is valid.
- `Transaction` is a GRDB `Record` subclass (reference type). The new `Transaction(...)` calls at lines 68-81, 85-98, 101-114 use the correct memberwise init with all 12 stored properties.
- `retryCount + 1` at line 97: `retryCount` is `Int`, arithmetic is safe (no overflow risk in practice).

**Error handling is correct.** `getBlockHeight()` failure causes early return (no partial updates). Per-transaction `getTransaction` failures are caught and treated as "not yet visible" (lines 60-64), matching Android behavior. `resendTransaction` errors are silently swallowed (line 138-139), matching Android.

**Storage interaction is correct.** `storage.updateTransactions(updatedTransactions)` calls GRDB `Record.update(_:)` which is a full-row UPDATE by primary key. Since we're updating rows that were just fetched by `pendingTransactions()`, the rows are guaranteed to exist — no `recordNotFound` risk. The `try?` at line 120 is appropriate as a last-resort guard.

### TransactionManager.swift — `notifyTransactionsUpdate`

Correct. Dispatches to `DispatchQueue.main` before calling `send()`, matching the existing pattern in `handle(...)` at lines 111-113. No new state mutation, just Combine emission.

### TransactionSyncer.swift — wiring

**Correct placement.** `await pendingTransactionSyncer.sync()` is called at line 89, before the `guard !syncState.syncing` check at line 91. This matches Android `TransactionSyncer.sync()` line 69 where `pendingTransactionSyncer.sync()` runs before the syncing guard. Pending transactions are polled on every heartbeat even when the main history sync is mid-flight.

### Kit.swift — factory wiring

Correct instantiation order: `TransactionManager` (line 213) → `PendingTransactionSyncer` (line 215) → `TransactionSyncer` (line 221). All dependencies are satisfied. `PendingTransactionSyncer` is owned by `TransactionSyncer`, not exposed to `SyncManager` — matches Android's composition model.

## Potential Concerns (Non-blocking)

### 1. No concurrency guard on `PendingTransactionSyncer.sync()`

Unlike `TransactionSyncer.sync()` which has `guard !syncState.syncing`, `PendingTransactionSyncer.sync()` has no reentrancy guard. If two heartbeats fire in quick succession while pending transactions exist, two concurrent `sync()` calls could both read the same pending transactions and both resend/update them.

**Severity: Low.** In practice, the `ApiSyncer` timer fires on `DispatchQueue.main` and `SyncManager.didUpdateLastBlockHeight` dispatches sync work in a single `Task`. The previous task's `pendingTransactionSyncer.sync()` must return before the main `TransactionSyncer.sync()` completes, and the next heartbeat's Task won't start its pending sync until the previous task's `await transactionSyncer?.sync()` returns (because they're called sequentially in the same `Task`). The Android version has the same design (no guard). **No action needed.**

### 2. `AnyCodable.description` for error field produces debug-style output

`response.meta?.err?.description` will produce strings like `Optional({"InstructionError": [0, {"Custom": 1}]})` — a debug representation of the underlying `Any` value, not a clean user-facing error message. This matches Android behavior where `meta.err?.toString()` produces similar Kotlin debug output. **No action needed** — this field is for internal diagnostics, not UI display.

### 3. Empty `base64Encoded` on retry

If a pending `Transaction` was created with the default `base64Encoded = ""` (e.g., because the send flow didn't populate it), `resendTransaction(base64Encoded: "")` will make a malformed RPC call. The error will be silently swallowed. **No action needed** — the send flow (Phase 4) is responsible for populating this field correctly. The error path is safe.

## Verdict

All changes are correct, type-safe, and faithfully port the Android behavior. Build passes. No bugs, no security issues, no race conditions.

REVIEW_PASS
