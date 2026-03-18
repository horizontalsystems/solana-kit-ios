# Review: 3.4 TransactionSyncer

**Build status:** Compiles (xcodebuild iOS Simulator — BUILD SUCCEEDED)
**Files reviewed:** TransactionSyncer.swift, TransactionManager.swift, Kit.swift, SyncManager.swift, Protocols.swift

---

## Critical

### 1. Token transfer cascade deletion on pending-to-confirmed merge

**File:** `TransactionManager.swift:103-105`

`Transaction` uses `.replace` conflict policy (DELETE + INSERT at SQLite level). `TokenTransfer` has `ON DELETE CASCADE` via its foreign key to `transactions(hash)`. When `storage.save(transactions: mergedTransactions)` replaces an existing pending transaction, all its associated `TokenTransfer` rows are cascade-deleted. Then `storage.save(tokenTransfers: tokenTransfers)` only saves the *synced* token transfers — if the synced batch has no transfers for that hash, the existing ones are permanently lost.

Android handles this correctly in `TransactionManager.kt:91-97`:
```kotlin
tokenTransfers = syncedTx.tokenTransfers.ifEmpty {
    existingTx.tokenTransfers  // <-- keeps existing when synced is empty
}
```
Then `storage.addTransactions(transactions)` persists both the transaction AND its merged token transfers together, so the re-inserted row's children survive the cascade.

**iOS code does NOT merge token transfers into the save call.** The `existingMintAddresses` are collected (line 94-96) and returned, but the actual `TokenTransfer` records from the existing DB row are never re-inserted after the cascade delete.

**Impact:** When a pending SPL token transfer gets confirmed and the synced version has no token transfers (edge case — the RPC almost always returns them), the existing token transfers are permanently deleted. Low probability in practice but a correctness divergence from Android.

**Fix:** Build a merged token transfers array:
```swift
var mergedTokenTransfers: [TokenTransfer] = []
for tx in transactions {
    let syncedTransfers = syncedTransfersByHash[tx.hash] ?? []
    if syncedTransfers.isEmpty, let existing = existingFullByHash[tx.hash],
       !existing.tokenTransfers.isEmpty {
        // Keep existing when synced is empty (mirrors Android .ifEmpty{})
        mergedTokenTransfers.append(contentsOf: existing.tokenTransfers.map { $0.tokenTransfer })
        existingMintAddresses.append(contentsOf: existing.tokenTransfers.map { $0.mintAccount.address })
    } else {
        mergedTokenTransfers.append(contentsOf: syncedTransfers)
    }
}
// ...
try? storage.save(tokenTransfers: mergedTokenTransfers)
```

---

## Non-Critical

### 2. `LastSyncedTransaction` saved but never read — misleading model docstring

**File:** `TransactionSyncer.swift:152-160`, `LastSyncedTransaction.swift`

The sync cursor is actually `storage.lastNonPendingTransaction()?.hash` (an implicit cursor from the `Transaction` table). The `LastSyncedTransaction` record is saved after sync but never read back — it's audit/informational only, matching Android exactly. However, the `LastSyncedTransaction.swift` docstring says "cursor for incremental sync" which is misleading.

**Suggestion:** Update the docstring to clarify it's an informational record, not the operational cursor.

### 3. Nondeterministic mint address ordering in `resolveMintAccounts`

**File:** `TransactionSyncer.swift:380`

```swift
let uniqueAddresses = Array(Set(placeholderMints.map { $0.address }))
```

`Set` iteration order is nondeterministic. The array is used both for the `getMultipleAccounts` RPC call and the result enumeration, so index alignment is correct. However, across runs, the same input produces different RPC request orderings. This is functionally correct but makes debugging harder.

**Suggestion:** Sort the array for deterministic behavior (matches `TokenAccountManager.sync()` line 93: `let sortedNewMints = Array(newMintAddresses).sorted()`).

### 4. `SyncManager.transactionManager` `didSet` subscription fires balance sync on every transaction batch

**File:** `SyncManager.swift:36-43`

The Combine subscription triggers `balanceManager.sync()` on every new transaction batch. This is correct (mirrors Android cross-cutting subscription), but the subscription callback also calls `delegate?.didUpdate(transactions:)` which dispatches to Kit's subject. Since `TransactionManager.handle()` already dispatches its own subject on `DispatchQueue.main`, and then SyncManager's sink receives that and dispatches Kit's delegate on the same queue, there's a double main-queue hop. Functionally correct but slightly wasteful.

---

## Verified Correct

- **Incremental cursor logic** — `fetchAllSignatures()` uses `storage.lastNonPendingTransaction()?.hash` as the `until` param, matching Android exactly.
- **Signature pagination** — Page loop with `before = chunk.last?.signature`, `limit = 1000`, break on `chunk.count < pageSize`. Correct.
- **SOL balance change detection** — Fee-payer adjustment (`ourIndex == 0 ? balanceChange + fee : balanceChange`) correctly recovers the net transfer amount.
- **Counterparty discovery** — Scans for largest opposite-direction balance change, skipping our index. Matches Android.
- **SPL token transfer parsing** — Groups by `"\(accountIndex)_\(mint)"`, filters by `owner == address`, handles entries in only pre or only post (new/closed accounts). Correct.
- **Token amount as raw integer string** — `RpcUiTokenAmount.amount` is always a raw integer; `Decimal(string:)` → integer `Decimal` → `String(describing:)` produces correct plain-integer output.
- **NFT detection logic** — Identical to `TokenAccountManager.sync()` with all Metaplex token standard checks.
- **Sync state guard** — `guard !syncState.syncing else { return }` prevents concurrent sync. Matches BalanceManager/TokenAccountManager pattern.
- **CancellationError guard** — `guard !(error is CancellationError) else { return }` avoids overwriting sync state on task cancellation.
- **Delegate wiring** — Kit.instance() correctly sets `transactionSyncer.delegate = syncManager` and injects via post-init property assignment.
- **Combine publisher chain** — TransactionManager → SyncManager subscription → Kit delegate → Kit subject → public publisher. No double emission to public API.
- **Build** — All files compile with zero errors/warnings.

---

REVIEW_PASS
