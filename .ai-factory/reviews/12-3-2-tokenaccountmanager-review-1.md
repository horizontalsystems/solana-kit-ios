# Review: 3.2 TokenAccountManager — Review 1

**Scope:** All staged changes — `Protocols.swift`, `SplMintLayout.swift`, `TokenAccountManager.swift`, `SyncManager.swift`, `Kit.swift`
**Build:** Compiles successfully on iOS Simulator (iPhone 17, iOS 26.1). Pre-existing Sendable warnings only.

---

## Critical

### 1. `getMultipleAccounts` / `newMintAddresses` ordering mismatch (TokenAccountManager.swift:89-91)

```swift
let bufferInfos = try await rpcApiProvider.getMultipleAccounts(addresses: Array(newMintAddresses))
for (index, mintAddress) in newMintAddresses.sorted().enumerated() {
    guard index < bufferInfos.count, let bufferInfo = bufferInfos[index] else { continue }
```

`getMultipleAccounts` is called with `Array(newMintAddresses)` — a `Set` iterated in arbitrary hash order. But the loop iterates over `newMintAddresses.sorted()` — alphabetical order. These two orderings are **different**, so `bufferInfos[index]` is paired with the **wrong** `mintAddress`. This will produce `MintAccount` records with wrong decimals, supply, and isNft for every mint that isn't at the same position in both orderings.

**Fix:** Use the same ordered array for both:
```swift
let sortedNewMints = Array(newMintAddresses).sorted()
let bufferInfos = try await rpcApiProvider.getMultipleAccounts(addresses: sortedNewMints)
for (index, mintAddress) in sortedNewMints.enumerated() {
```

---

## Minor

### 2. Unused `existingMintAddresses` parameter (TokenAccountManager.swift:135)

```swift
func addAccount(receivedTokenAccounts: [TokenAccount], existingMintAddresses: [String]) async {
    try? storage.save(tokenAccounts: receivedTokenAccounts)
    await sync()
}
```

`existingMintAddresses` is never read. In Android, it's used to merge existing accounts with new ones before syncing a subset. The iOS version does a full `getTokenAccountsByOwner` sync instead, making the parameter dead code. Not a runtime bug — the full sync is functionally correct — but the unused parameter should be removed or marked with `_ existingMintAddresses` to signal intent. Since `TransactionSyncer` (milestone 3.4) will call this method, decide now whether to keep the parameter for API compatibility or drop it.

### 3. `readLE` endianness — technically correct, potentially confusing (SplMintLayout.swift:96-98)

```swift
func readLE<T: FixedWidthInteger>(offset: Int) -> T {
    let size = MemoryLayout<T>.size
    return subdata(in: offset ..< offset + size).withUnsafeBytes { ptr in
        ptr.loadUnaligned(as: T.self).littleEndian
    }
}
```

`loadUnaligned` interprets raw bytes in platform-native order. `.littleEndian` then produces the LE representation. Mathematically, `T(littleEndian: x)` and `x.littleEndian` are the same swap operation, so this yields the correct value on all platforms. However, the conventional idiom for "these bytes are LE, give me the native value" is `T(littleEndian: rawValue)`. The current form reads as "give me the LE representation of this native value" — semantically backwards even though numerically identical. Not a bug, but could confuse future readers.

### 4. `initialSynced` flag ownership (TokenAccountManager.swift:119-121)

```swift
if !mainStorage.initialSynced() {
    try? mainStorage.setInitialSynced()
}
```

`TokenAccountManager` now owns the `initialSynced` flag, matching Android. But `IMainStorage`'s docstring says "Returns `true` after the initial full **transaction** history fetch has completed." When `TransactionSyncer` is added in milestone 3.4, it should NOT also call `setInitialSynced()` — the flag is already set after the first `TokenAccountManager.sync()`. If TransactionSyncer needs its own "first sync" flag, a separate flag will be needed. No action needed now, but worth noting for milestone 3.4 planning.

### 5. Silent storage write failures (TokenAccountManager.swift:105-106)

```swift
try? storage.save(tokenAccounts: tokenAccounts)
try? storage.save(mintAccounts: mintAccounts)
```

If either write fails, the sync still reports `.synced` and the delegate receives stale data from `storage.fullTokenAccounts()`. This matches the `BalanceManager` pattern (`try? storage.save(balance:)`) and is consistent with EvmKit, so it's a deliberate convention. Just noting that a DB failure will silently produce stale results.

---

## Observations (no action needed)

- **Protocols.swift:** `ITokenAccountManagerDelegate` and `ISyncManagerDelegate` extensions are clean, follow `IBalanceManagerDelegate` pattern exactly.
- **SplMintLayout.swift:** Binary layout parsing is correct — offsets match the SPL Token program's Mint account structure. `ParseError` is well-defined. `isNft` logic (`decimals == 0 && supply == 1 && mintAuthority == nil`) matches the basic Android NFT detection.
- **SyncManager.swift:** Balance and token account syncs run sequentially in the same `Task` — this is correct (mirrors Android coroutine scope). Both stopped on `.notReady`.
- **Kit.swift:** `TransactionStorage` is now created in `Kit.instance()` and passed to `TokenAccountManager`. Subjects are seeded from storage. Delegate wiring is complete. All new publishers dispatch on `DispatchQueue.main`.
- **Kit.swift line 165:** `tokenAccountManager.tokenAccounts().filter { !$0.mintAccount.isNft }` — correct for seeding the initial fungible list from DB at startup.
- **Build:** No new warnings introduced.

---

## Verdict

One critical bug (item 1) must be fixed before merge. Items 2-5 are minor.

REVIEW_FAIL
