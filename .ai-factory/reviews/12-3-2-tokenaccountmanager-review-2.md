# Review: 3.2 TokenAccountManager — Review 2

**Scope:** All staged changes — `Protocols.swift`, `SplMintLayout.swift`, `TokenAccountManager.swift`, `SyncManager.swift`, `Kit.swift`
**Build:** Compiles with 0 errors on iOS Simulator (iPhone 17, iOS 26.1). Only pre-existing Sendable warnings (same pattern as `BalanceManager`, `RpcApiProvider`, etc.).
**Prior review:** Review 1 found one critical bug (mint address / buffer ordering mismatch) and three minor items. All have been addressed in the current code.

---

## Review 1 Fix Verification

| Review 1 Item | Status | Verification |
|---|---|---|
| Critical #1: `getMultipleAccounts` ordering mismatch | **Fixed** | `sortedNewMints` is now used for both the RPC call (line 91) and the iteration loop (line 92). Same array, guaranteed matching indices. |
| Minor #2: Unused `existingMintAddresses` | **Fixed** | Parameter renamed to `existingMintAddresses _: [String]` (line 136) — signals intentional non-use while preserving API shape for milestone 3.4. |
| Minor #3: `readLE` endianness idiom | **Fixed** | Now uses `T(littleEndian: ptr.loadUnaligned(as: T.self))` (line 97) — the conventional idiom for "interpret these bytes as LE". |
| Minor #4: `initialSynced` flag ownership | Acknowledged | No code change needed — noted for milestone 3.4 planning. |
| Minor #5: Silent storage write failures | Acknowledged | Deliberate project convention, consistent with `BalanceManager`. |

---

## Fresh Review of Current Code

### Critical

None found.

### Minor

#### 1. `getMultipleAccounts` has a 100-account RPC limit (TokenAccountManager.swift:91)

Solana's `getMultipleAccounts` RPC method accepts a maximum of 100 addresses per call. If a wallet holds tokens from >100 new mints on first sync, the RPC call will fail with an error (or be truncated depending on the RPC provider). This is unlikely for typical wallets but possible for airdrop-heavy addresses.

The current code passes all new mint addresses in a single call:
```swift
let bufferInfos = try await rpcApiProvider.getMultipleAccounts(addresses: sortedNewMints)
```

Since this would be caught by the `catch` block (setting `.notSynced(error:)`), it won't crash — but it will prevent sync from ever completing for such wallets. Consider chunking in a future iteration if this becomes an issue. Not blocking for MVP.

#### 2. `storage.fullTokenAccounts()` called on background thread (TokenAccountManager.swift:110)

The GRDB read at line 110 (`storage.fullTokenAccounts()`) runs on the `Task` context (background thread), which is fine — GRDB `DatabasePool` supports concurrent reads. The result is then dispatched to `DispatchQueue.main` for the delegate callback. This is correct and matches the `BalanceManager` pattern.

No issue — just confirming the threading is safe.

---

## File-by-File Walkthrough

### Protocols.swift
- `ITokenAccountManagerDelegate`: clean, follows `IBalanceManagerDelegate` pattern exactly (2 methods, `AnyObject`, weak-compatible).
- `ISyncManagerDelegate` extended with matching methods. All 5 delegate methods now cover balance, block height, and token accounts — ready for `TransactionSyncer` in milestone 3.4.
- No protocol method collisions or ambiguity.

### SplMintLayout.swift
- Binary layout offsets verified against the SPL Token program's Mint account struct: `mintAuthorityOption` (0–3), `mintAuthority` (4–35), `supply` (36–43), `decimals` (44), `isInitialized` (45), `freezeAuthorityOption` (46–49), `freezeAuthority` (50–81). All correct.
- `readLE` helper uses `subdata(in:)` which resets startIndex to 0 before `withUnsafeBytes` — safe for unaligned loads.
- `Base58.encode(_:)` accepts `Data` (confirmed at `Helper/Base58.swift:19`) — data slices from subscript `data[4..<36]` are valid `Data` values.
- `isNft` computed property: `decimals == 0 && supply == 1 && mintAuthority == nil` matches the basic Android NFT detection logic. Advanced Metaplex detection deferred to 3.3 as planned.
- `ParseError.dataTooShort` is well-formed with expected vs actual for debugging.

### TokenAccountManager.swift
- **Sync guard** (line 64): `guard !syncState.syncing` prevents concurrent in-flight requests. Same pattern as `BalanceManager`.
- **RPC → model conversion** (lines 73–81): Maps `RpcKeyedAccount` fields correctly — `pubkey` → `address`, `info.mint` → `mintAddress`, `info.tokenAmount.amount` → `balance` (String), `info.tokenAmount.decimals` → `decimals` (Int).
- **New mint detection** (line 85): Filters via `storage.mintAccount(address:)` per unique mint — N queries for N unique mints. For initial sync with many tokens this could be chatty, but GRDB reads are fast and this runs off main thread.
- **Supply clamping** (line 98): `layout.supply <= Int64.max ? Int64(layout.supply) : Int64.max` — correct, prevents crash on tokens with supply > `Int64.max`.
- **Delegate notification** (lines 114–116): `DispatchQueue.main.async` with `[weak self]` capture — matches the `BalanceManager` pattern. The `accounts` local is captured by value (array of structs), avoiding a retain cycle.
- **`addAccount`** (lines 136–138): Saves then re-syncs. The `_: [String]` parameter is correctly suppressed.
- **`addTokenAccount`** (lines 145–160): Creates zero-balance `TokenAccount` + placeholder `MintAccount`. The `MintAccount` uses `insert: .ignore` conflict policy (from model definition), so it won't overwrite existing enriched metadata. Correct.
- **`stop`** (lines 180–181): Mirrors `BalanceManager.stop` exactly.

### SyncManager.swift
- `tokenAccountManager` added alongside `balanceManager` — same lifecycle pattern.
- `didUpdateLastBlockHeight`: both `balanceManager.sync()` and `tokenAccountManager.sync()` are `await`ed sequentially in the same `Task`. This means token sync only starts after balance sync completes. This is fine — matches Android where both launch in the same coroutine scope (though Android uses `launch` for parallel execution). Sequential is safer and the performance difference is negligible.
- `didUpdateSyncerState(.notReady)`: both managers stopped — correct.
- `refresh()`: both synced — correct.
- `ITokenAccountManagerDelegate` conformance: pass-through to `ISyncManagerDelegate`. Clean.

### Kit.swift
- `TransactionStorage` created at line 126 with `walletId` and `address` — correct, matches `TransactionStorage.init(walletId:address:)`.
- `tokenAccountManager` wired with `transactionStorage` (not `mainStorage`) for token/mint persistence — correct per architecture (two separate databases).
- Subjects seeded: `tokenBalanceSyncStateSubject` starts at `.notSynced(error: .notStarted)`, `fungibleTokenAccountsSubject` starts from DB — correct.
- Delegate chain: `tokenAccountManager.delegate = syncManager` (line 177) + `syncManager.delegate = kit` (line 193) — complete.
- All 5 `ISyncManagerDelegate` methods implemented (lines 230–261), all dispatch on `DispatchQueue.main` — correct.
- No schema migration needed — `TransactionStorage` already has `tokenAccounts` and `mintAccounts` tables from milestone 1.6.

---

## Verdict

All review 1 issues have been fixed. No new critical issues found. One minor note about the 100-account `getMultipleAccounts` limit (non-blocking for MVP). Code is clean, patterns are consistent with `BalanceManager`, and the full delegate chain is correctly wired.

REVIEW_PASS
