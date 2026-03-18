# Plan: 3.2 TokenAccountManager

## Context

Implement the `TokenAccountManager` subsystem: fetch SPL token accounts via RPC (`getTokenAccountsByOwner`), parse on-chain mint data for NFT-vs-fungible distinction, persist token/mint accounts in `TransactionStorage`, and wire the manager into `SyncManager`/`Kit` with Combine publishers. This mirrors Android `TokenAccountManager.kt` with iOS idioms.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Protocols and helpers

- [x] **Task 1: Add ITokenAccountManagerDelegate and extend ISyncManagerDelegate**
  Files: `Sources/SolanaKit/Core/Protocols.swift`
  Add a new `ITokenAccountManagerDelegate` protocol following the same pattern as `IBalanceManagerDelegate`:
  ```swift
  protocol ITokenAccountManagerDelegate: AnyObject {
      func didUpdate(tokenAccounts: [FullTokenAccount])
      func didUpdate(tokenBalanceSyncState: SyncState)
  }
  ```
  Extend `ISyncManagerDelegate` with two new methods so `Kit` receives token account events:
  ```swift
  func didUpdate(tokenAccounts: [FullTokenAccount])
  func didUpdate(tokenBalanceSyncState: SyncState)
  ```

- [x] **Task 2: Create SplMintLayout helper for parsing mint account binary data** (depends on Task 1)
  Files: `Sources/SolanaKit/Helper/SplMintLayout.swift` (new file)
  Parse the 82-byte SPL Mint account layout returned by `getMultipleAccounts` (base64 encoding). The layout is:
  - Bytes 0-3: `mintAuthorityOption` (u32 LE, 0 = None, 1 = Some)
  - Bytes 4-35: `mintAuthority` (32-byte PublicKey, valid only if option == 1)
  - Bytes 36-43: `supply` (u64 LE)
  - Byte 44: `decimals` (u8)
  - Byte 45: `isInitialized` (bool)
  - Bytes 46-49: `freezeAuthorityOption` (u32 LE)
  - Bytes 50-81: `freezeAuthority` (32-byte PublicKey)

  Create a `struct SplMintLayout` with an `init(data: Data) throws` initializer that extracts `mintAuthority: String?`, `supply: UInt64`, `decimals: UInt8`, `isInitialized: Bool`, `freezeAuthority: String?`. Use `Data` subscript slicing + `withUnsafeBytes` for little-endian integer reads. Throw if `data.count < 82`. Encode PublicKey bytes to Base58 via `Base58.encode(_:)`.

  Also add a computed property for basic NFT detection:
  ```swift
  var isNft: Bool {
      decimals == 0 && supply == 1 && mintAuthority == nil
  }
  ```
  This covers the simplest NFT case (decimals 0, supply 1, frozen mint authority). Advanced Metaplex-based detection is deferred to milestone 3.3.

### Phase 2: Core manager

- [x] **Task 3: Create TokenAccountManager** (depends on Tasks 1-2)
  Files: `Sources/SolanaKit/Core/TokenAccountManager.swift` (new file)
  Port Android `TokenAccountManager.kt` following the `BalanceManager.swift` pattern (delegate, sync state `didSet`, `final class`).

  **Dependencies (injected via init):**
  - `address: String` — wallet Base58 address
  - `rpcApiProvider: IRpcApiProvider` — for RPC calls
  - `storage: ITransactionStorage` — for token/mint account persistence
  - `mainStorage: IMainStorage` — for `initialSynced()` flag

  **Delegate:** `weak var delegate: ITokenAccountManagerDelegate?`

  **Sync state:** `private(set) var syncState: SyncState` — with `didSet` guard + `DispatchQueue.main.async` delegate notification (identical pattern to `BalanceManager`).

  **`func sync() async`** — main sync entry point, called by `SyncManager` on each block height tick:
  1. Guard `!syncState.syncing`, set `.syncing(progress: nil)`
  2. Call `rpcApiProvider.getTokenAccountsByOwner(address: address)` to get all on-chain SPL token accounts with parsed balances
  3. Convert each `RpcKeyedAccount` to a `TokenAccount` record (ATA address from `pubkey`, mint from `info.mint`, balance from `info.tokenAmount.amount`, decimals from `info.tokenAmount.decimals`)
  4. Collect mint addresses not already in `storage` (call `storage.mintAccount(address:)` for each unique mint)
  5. For new mints: call `rpcApiProvider.getMultipleAccounts(addresses:)` on the mint addresses, parse each `BufferInfo.data` via `SplMintLayout`, create `MintAccount` records with `decimals`, `supply`, `isNft` from layout
  6. Save token accounts via `storage.save(tokenAccounts:)` and mint accounts via `storage.save(mintAccounts:)`
  7. Read the full joined list via `storage.fullTokenAccounts()`, filter to `!mintAccount.isNft` for fungible accounts
  8. Check `mainStorage.initialSynced()` — on first sync, emit ALL fungible accounts as new
  9. Notify delegate: `delegate?.didUpdate(tokenAccounts: fungibleAccounts)` on `DispatchQueue.main`
  10. Set `syncState = .synced`
  11. On error: set `.notSynced(error:)`, guard `CancellationError`

  **`func addAccount(receivedTokenAccounts: [TokenAccount], existingMintAddresses: [String]) async`** — called by `TransactionSyncer` (milestone 3.4) when new token accounts are discovered in transaction parsing. Saves the new accounts to storage, then calls `sync()` to refresh everything.

  **`func addTokenAccount(ataAddress: String, mintAddress: String, decimals: Int)`** — pre-registers a token account for send-SPL (mirrors Android `addTokenAccount`). Checks `storage.tokenAccountExists(mintAddress:)` first. Creates `TokenAccount` with zero balance and `MintAccount` placeholder. Note: the ATA address must be pre-computed by the caller; PDA derivation (`PublicKey.findProgramAddress`) will be added in milestone 4.4.

  **Synchronous reads:**
  - `func fullTokenAccount(mintAddress: String) -> FullTokenAccount?` — delegates to `storage.fullTokenAccount(mintAddress:)`
  - `func tokenAccounts() -> [FullTokenAccount]` — delegates to `storage.fullTokenAccounts()`

  **`func stop(error: Error? = nil)`** — sets `.notSynced(error: error ?? SyncError.notStarted)`.

### Phase 3: Wiring

- [x] **Task 4: Update SyncManager to drive TokenAccountManager** (depends on Task 3)
  Files: `Sources/SolanaKit/Core/SyncManager.swift`
  Add `tokenAccountManager: TokenAccountManager` as a stored property, passed via `init`.

  Changes to `init`:
  ```swift
  init(apiSyncer: ApiSyncer, balanceManager: BalanceManager, tokenAccountManager: TokenAccountManager)
  ```

  Add a computed accessor:
  ```swift
  var tokenBalanceSyncState: SyncState { tokenAccountManager.syncState }
  ```

  In `IApiSyncerDelegate` extension:
  - `didUpdateSyncerState(.notReady(let error))`: add `tokenAccountManager.stop(error: error)` alongside `balanceManager.stop(...)`.
  - `didUpdateLastBlockHeight(_:)`: add `await self?.tokenAccountManager.sync()` inside the existing `Task { }` block, alongside `balanceManager.sync()`.

  In the `refresh()` method: add `tokenAccountManager.sync()` call inside the ready-state branch Task, alongside `balanceManager.sync()`.

  Add `ITokenAccountManagerDelegate` conformance (new extension):
  ```swift
  extension SyncManager: ITokenAccountManagerDelegate {
      func didUpdate(tokenAccounts: [FullTokenAccount]) {
          delegate?.didUpdate(tokenAccounts: tokenAccounts)
      }
      func didUpdate(tokenBalanceSyncState: SyncState) {
          delegate?.didUpdate(tokenBalanceSyncState: tokenBalanceSyncState)
      }
  }
  ```

- [x] **Task 5: Update Kit with token account publishers and TransactionStorage wiring** (depends on Task 4)
  Files: `Sources/SolanaKit/Core/Kit.swift`

  **New stored properties:**
  - `private let tokenAccountManager: TokenAccountManager`
  - `private let tokenBalanceSyncStateSubject: CurrentValueSubject<SyncState, Never>`
  - `private let fungibleTokenAccountsSubject: CurrentValueSubject<[FullTokenAccount], Never>`

  **New public publishers:**
  ```swift
  public var tokenBalanceSyncStatePublisher: AnyPublisher<SyncState, Never>
  public var fungibleTokenAccountsPublisher: AnyPublisher<[FullTokenAccount], Never>
  ```

  **New public accessors:**
  ```swift
  public var tokenBalanceSyncState: SyncState { tokenBalanceSyncStateSubject.value }
  public func fungibleTokenAccounts() -> [FullTokenAccount] { fungibleTokenAccountsSubject.value }
  public func fullTokenAccount(mintAddress: String) -> FullTokenAccount? { tokenAccountManager.fullTokenAccount(mintAddress: mintAddress) }
  ```

  **Update `Kit.instance(address:rpcSource:walletId:)`:**
  1. Create `TransactionStorage` via `TransactionStorage(walletId: walletId, address: address)`
  2. Create `TokenAccountManager(address:rpcApiProvider:storage:mainStorage:)`
  3. Seed `fungibleTokenAccountsSubject` with `tokenAccountManager.tokenAccounts().filter { !$0.mintAccount.isNft }` (restore from DB)
  4. Pass `tokenAccountManager` to `SyncManager` init (updated signature)
  5. Wire `tokenAccountManager.delegate = syncManager`
  6. Pass new subjects to `Kit` init (update the private init signature)

  **Extend `ISyncManagerDelegate` conformance:**
  ```swift
  func didUpdate(tokenAccounts: [FullTokenAccount]) {
      DispatchQueue.main.async { [weak self] in
          self?.fungibleTokenAccountsSubject.send(tokenAccounts)
      }
  }
  func didUpdate(tokenBalanceSyncState: SyncState) {
      DispatchQueue.main.async { [weak self] in
          self?.tokenBalanceSyncStateSubject.send(tokenBalanceSyncState)
      }
  }
  ```

## Commit Plan
- **Commit 1** (after tasks 1-2): "Add ITokenAccountManagerDelegate protocol and SplMintLayout helper"
- **Commit 2** (after tasks 3-5): "Implement TokenAccountManager and wire into SyncManager and Kit"
