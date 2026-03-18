# Plan: 3.4 TransactionSyncer

## Context

Implement the transaction history sync pipeline — the largest single component in the kit. `TransactionSyncer` fetches transaction signatures for the wallet address, batch-fetches full transaction details, parses SOL balance changes and SPL token transfers from pre/post balance deltas, resolves mint metadata for newly seen tokens, and persists everything via `TransactionStorage`. It also wires into `TransactionManager` (new) which holds the Combine publisher, and extends `SyncManager` + `Kit` to expose the transaction sync state and transaction stream to consumers.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: TransactionManager — aggregation layer and Combine plumbing

- [x] **Task 1: Create TransactionManager**
  Files: `Sources/SolanaKit/Transactions/TransactionManager.swift`
  Create `TransactionManager` class that owns the transaction Combine subjects and coordinates storage reads. Dependencies: `ITransactionStorage`, `address: String`. It must:
  - Hold a `PassthroughSubject<[FullTransaction], Never>` for emitting newly synced transaction batches.
  - Expose `transactionsPublisher: AnyPublisher<[FullTransaction], Never>` (erased).
  - Implement `handle(transactions:tokenTransfers:mintAccounts:tokenAccounts:)` — the main entry point called by `TransactionSyncer` after parsing. This method:
    (a) Queries existing DB records for the same hashes via `storage.fullTransactions(hashes:)`.
    (b) Merges: for transactions already in DB (e.g. pending → confirmed), prefer synced `from`/`to`/`amount` if non-nil, fall back to DB values; always set `pending = false`, copy `error` from synced data. If synced `tokenTransfers` is empty but DB version has them, keep existing.
    (c) Persists via `storage.save(transactions:)`, `storage.save(tokenTransfers:)`, `storage.save(mintAccounts:)`.
    (d) Sends the batch to `transactionsSubject` on `DispatchQueue.main`.
    (e) Returns a list of `TokenAccount` records and a list of existing mint addresses that need re-resolution (for `TokenAccountManager.addAccount`).
  - Implement read queries delegating to storage: `transactions(incoming:fromHash:limit:)`, `solTransactions(incoming:fromHash:limit:)`, `splTransactions(mintAddress:incoming:fromHash:limit:)`.
  Follow the pattern from Android `TransactionManager.handle()` for merge logic. Follow `BalanceManager`/`TokenAccountManager` for Swift code style.

- [x] **Task 2: Add ITransactionManagerDelegate protocol and wire into SyncManager**
  Files: `Sources/SolanaKit/Core/Protocols.swift`, `Sources/SolanaKit/Core/SyncManager.swift`
  Add to `Protocols.swift`:
  - `ITransactionSyncerDelegate` protocol with method `didUpdate(transactionsSyncState: SyncState)`. This mirrors `IBalanceManagerDelegate` / `ITokenAccountManagerDelegate`.
  Add to `ISyncManagerDelegate`:
  - `didUpdate(transactionsSyncState: SyncState)` method.
  - `didUpdate(transactions: [FullTransaction])` method.
  Update `SyncManager`:
  - Add `transactionSyncer` property (type will be `TransactionSyncer`, set after Task 4).
  - Add `transactionManager` property (type `TransactionManager`).
  - Conform to `ITransactionSyncerDelegate`: forward `didUpdate(transactionsSyncState:)` to `delegate`.
  - In `didUpdateLastBlockHeight(_:)`, add `transactionSyncer.sync()` call alongside the existing `balanceManager.sync()` and `tokenAccountManager.sync()`.
  - In `didUpdateSyncerState(.notReady)`, add `transactionSyncer.stop(error:)`.
  - In `refresh()`, add `transactionSyncer.sync()`.
  - Add `transactionsSyncState` computed property.
  - Subscribe to `transactionManager.transactionsPublisher` — when new transactions arrive, trigger `balanceManager.sync()` (matching Android's cross-cutting subscription that refreshes balance after new txs).

### Phase 2: TransactionSyncer — core sync engine

- [x] **Task 3: Create TransactionSyncer with signature fetching**
  Files: `Sources/SolanaKit/Transactions/TransactionSyncer.swift`
  Create `TransactionSyncer` class. Dependencies: `address: String`, `IRpcApiProvider`, `INftClient`, `ITransactionStorage`, `TransactionManager`, `TokenAccountManager`. Follow the pattern of `TokenAccountManager` for sync state management, delegate pattern, and guard against concurrent sync. Implement:
  - `syncState` property with `didSet` that notifies `delegate: ITransactionSyncerDelegate?` on `DispatchQueue.main` (same pattern as `TokenAccountManager.syncState`).
  - `stop(error:)` method.
  - Constants: `signaturesPageSize = 1000`, `batchChunkSize = 100`, `syncSourceName = "rpc/getSignaturesForAddress"`.
  - Private method `fetchAllSignatures() async throws -> [SignatureInfo]`:
    (a) Get cursor: `storage.lastNonPendingTransaction()?.hash` — this is the `until` parameter.
    (b) Page loop: call `rpcApiProvider.getSignaturesForAddress(address:limit:before:until:)` with `limit = 1000`. First call has `before = nil`. Subsequent calls use `before = lastSignature` from previous chunk. Continue while chunk count == 1000.
    (c) Return all collected `SignatureInfo` objects (newest first, as Solana RPC returns them).

- [x] **Task 4: Implement transaction parsing logic** (depends on Task 3)
  Files: `Sources/SolanaKit/Transactions/TransactionSyncer.swift`
  Add private method `parseTransaction(signature: String, response: RpcTransactionResponse) -> ParsedTransaction` that returns a `ParsedTransaction` struct (private to this file) containing: `transaction: Transaction`, `tokenTransfers: [TokenTransfer]`, `mintAccounts: [MintAccount]`, `tokenAccounts: [TokenAccount]`.
  Parsing algorithm (mirrors Android `TransactionSyncer.parseTransaction`):
  - Extract `accountKeys` from `response.transaction?.message?.accountKeys` as array of pubkey strings.
  - Find `ourIndex` — index of `self.address` in accountKeys.
  - **SOL balance change:** `balanceChange = meta.postBalances[ourIndex] - meta.preBalances[ourIndex]`. If `ourIndex == 0` (fee payer), add `meta.fee` back to get the net transfer amount. If `adjustedChange != 0`, determine direction: positive → incoming (set `to = address`, find counterparty as `from`), negative → outgoing (set `from = address`, find counterparty as `to`). Store `amount` as `String(abs(adjustedChange))` (raw lamports, NOT shifted to SOL).
  - **Fee:** Store as `String(meta.fee)` (raw lamports as string, matching how `amount` is stored).
  - **Counterparty discovery:** `findCounterparty(preBalances:postBalances:accountKeys:ourIndex:incoming:)` — scan all account indices except `ourIndex`; for incoming, find the index with the largest decrease; for outgoing, find the index with the largest increase. Return `accountKeys[bestIndex]`.
  - **SPL token transfers:** Iterate `meta.preTokenBalances` and `meta.postTokenBalances`. Group by composite key `"\(accountIndex)_\(mint)"`. Filter to entries where `owner == self.address`. Calculate `change = postAmount - preAmount` (parse `amount` string to `Decimal`). Skip if change == 0. Create `TokenTransfer(transactionHash: signature, mintAddress: mint, incoming: change > 0, amount: String(describing: abs(change)))`. Create placeholder `MintAccount(address: mint, decimals: decimals)`. Extract `TokenAccount(address: accountKeys[accountIndex], mintAddress: mint, balance: "0", decimals: decimals)`.
  - Build `Transaction(hash: signature, timestamp: blockTime ?? 0, fee: feeString, from: from, to: to, amount: amountString, error: meta.err?.description, pending: false)`.

- [x] **Task 5: Implement mint metadata resolution** (depends on Task 4)
  Files: `Sources/SolanaKit/Transactions/TransactionSyncer.swift`
  Add private method `resolveMintAccounts(placeholderMints: [MintAccount]) async -> [MintAccount]` that upgrades placeholder `MintAccount` records with full metadata. Algorithm (mirrors Android `TransactionSyncer.getMintAccounts` + `NftClient.findAllByMintList`):
  - Collect unique mint addresses from the placeholders.
  - Filter out mint addresses already in storage (`storage.mintAccount(address:) != nil`).
  - If no new mints, return the original placeholders.
  - Call `rpcApiProvider.getMultipleAccounts(addresses:)` for the new mint addresses — parse each `BufferInfo.data` via `SplMintLayout(data:)` to get `decimals`, `supply`, `mintAuthority`.
  - Call `nftClient.findAllByMintList(mintAddresses:)` (wrapping in `try?` — graceful degradation if Metaplex fetch fails, matching Android).
  - Apply NFT detection logic (same as `TokenAccountManager.sync()`): `decimals != 0` → false; `supply == 1 && mintAuthority == nil` → true; check Metaplex `tokenStandard` ∈ {`.nonFungible`, `.fungibleAsset`, `.nonFungibleEdition`, `.programmableNonFungible`} → true.
  - Build full `MintAccount` with name/symbol/uri/collectionAddress from Metaplex metadata.
  - Replace each placeholder in the original array with the resolved version (or keep placeholder if resolution failed).

- [x] **Task 6: Implement the main sync() orchestration** (depends on Tasks 3, 4, 5)
  Files: `Sources/SolanaKit/Transactions/TransactionSyncer.swift`
  Implement the `sync() async` method that orchestrates the full pipeline. Algorithm (mirrors Android `TransactionSyncer.sync()`):
  1. Guard: if `syncState.syncing`, return immediately.
  2. Set `syncState = .syncing(progress: nil)`.
  3. Call `fetchAllSignatures()`. If empty, set `.synced` and return.
  4. Call `rpcApiProvider.fetchTransactionsBatch(signatures:)` — the batch-fetch method already exists and chunks into groups of 100 internally.
  5. For each signature with a non-nil response, call `parseTransaction(signature:response:)`.
  6. Collect all placeholder `MintAccount` records from parsed results.
  7. Call `resolveMintAccounts(placeholderMints:)`.
  8. Replace placeholder mint accounts in parsed results with resolved versions.
  9. Flatten all `Transaction`, `TokenTransfer`, `MintAccount`, `TokenAccount` records from parsed results.
  10. Call `transactionManager.handle(transactions:tokenTransfers:mintAccounts:tokenAccounts:)`.
  11. If `handle` returns token accounts / existing mint addresses needing resolution, call `tokenAccountManager.addAccount(receivedTokenAccounts:existingMintAddresses:)`.
  12. Save `LastSyncedTransaction(syncSourceName: syncSourceName, hash: newestSignature)` via `storage.save(lastSyncedTransaction:)`.
  13. Set `syncState = .synced`.
  14. On error: set `syncState = .notSynced(error:)`, guard against `CancellationError`.

### Phase 3: Kit + SyncManager wiring

- [x] **Task 7: Wire TransactionSyncer and TransactionManager into Kit** (depends on Tasks 1, 2, 6)
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Update `Kit`:
  - Add private properties: `transactionManager: TransactionManager`, `transactionSyncer: TransactionSyncer`.
  - Add Combine subjects: `transactionsSyncStateSubject: CurrentValueSubject<SyncState, Never>`, `transactionsSubject: PassthroughSubject<[FullTransaction], Never>`.
  - Add public publishers: `transactionsSyncStatePublisher`, `transactionsPublisher`.
  - Add public query methods: `transactions(incoming:fromHash:limit:)`, `solTransactions(incoming:fromHash:limit:)`, `splTransactions(mintAddress:incoming:fromHash:limit:)`.
  - Update `ISyncManagerDelegate` conformance: implement `didUpdate(transactionsSyncState:)` and `didUpdate(transactions:)`.
  - Update `Kit.instance()` factory:
    (a) Create `TransactionManager(storage: transactionStorage, address: address)`.
    (b) Create `TransactionSyncer(address:rpcApiProvider:nftClient:storage:transactionManager:tokenAccountManager:)`.
    (c) Pass both to `SyncManager` init (update SyncManager init signature).
    (d) Wire `transactionSyncer.delegate = syncManager`.
    (e) Pass the new subjects into `Kit` init.
  - Update `init` to accept the new parameters.

- [x] **Task 8: Verify build and fix compilation** (depends on Task 7)
  Files: `Sources/SolanaKit/Transactions/TransactionSyncer.swift`, `Sources/SolanaKit/Transactions/TransactionManager.swift`, `Sources/SolanaKit/Core/Kit.swift`, `Sources/SolanaKit/Core/SyncManager.swift`, `Sources/SolanaKit/Core/Protocols.swift`
  Run `swift build`. Fix any compilation errors — missing imports, type mismatches, protocol conformance issues. Ensure all new types are `internal` (not `public`) except the publishers and query methods on `Kit`. Verify the `Transactions/` directory is included in the SPM target sources.

## Commit Plan
- **Commit 1** (after tasks 1-2): "Add TransactionManager and transaction sync delegate protocols"
- **Commit 2** (after tasks 3-6): "Implement TransactionSyncer with full sync pipeline"
- **Commit 3** (after tasks 7-8): "Wire TransactionSyncer into Kit and SyncManager"
