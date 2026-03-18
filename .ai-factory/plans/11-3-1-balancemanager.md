# Plan: 3.1 BalanceManager

## Context

Implement `BalanceManager` — the core business logic component that fetches the SOL balance via RPC, caches it in `MainStorage`, tracks its own sync state, and notifies `Kit` of changes via Combine. This also requires creating `SyncManager` (the orchestrator that connects `ApiSyncer` heartbeats to `BalanceManager.sync()`) and wiring both into `Kit` with Combine publishers.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: BalanceManager Core

- [x] **Task 1: Create BalanceManager**
  Files: `Sources/SolanaKit/Core/BalanceManager.swift`
  Create `BalanceManager` as an internal `final class` with the following:
  - **Dependencies** (injected via init): `address: String`, `rpcApiProvider: IRpcApiProvider`, `storage: IMainStorage`, `balanceSubject: CurrentValueSubject<Decimal, Never>`, `syncStateSubject: CurrentValueSubject<SyncState, Never>`
  - **Init**: restore last known balance from `storage.balance()` (returns `Int64?` lamports), convert to `Decimal` (divide by 1_000_000_000), send to `balanceSubject`. If nil, leave subject at its initial value.
  - **`var balance: Decimal?`** — in-memory cached balance (set on init from storage, updated on sync). This avoids re-reading storage on every access.
  - **`var syncState: SyncState`** — private(set), starts as `.notSynced(error: SyncError.notStarted)`. On `didSet`, if `syncState != oldValue`, dispatch `syncStateSubject.send(syncState)` on `DispatchQueue.main`.
  - **`func sync() async`** — the main sync method:
    1. Guard: if `syncState` is already `.syncing`, return immediately (in-flight guard, matches Android).
    2. Set `syncState = .syncing(progress: nil)`.
    3. `do { let lamports = try await rpcApiProvider.getBalance(address: address)` — uses the existing `IRpcApiProvider` extension method.
    4. Call `handleBalance(lamports)`.
    5. `} catch { syncState = .notSynced(error: error) }`.
  - **`private func handleBalance(_ lamports: Int64)`** — deduplication + persistence + notification:
    1. Convert `lamports` to `Decimal`: `Decimal(lamports) / 1_000_000_000`.
    2. If `self.balance != newBalance`: update `self.balance`, call `try? storage.save(balance: lamports)`, dispatch `balanceSubject.send(newBalance)` on `DispatchQueue.main`.
    3. Always set `syncState = .synced` (even if value didn't change).
  - **`func stop(error: Error? = nil)`** — sets `syncState = .notSynced(error: error ?? SyncError.notStarted)`. Does not clear the cached balance.
  - Follow the Android `BalanceManager.kt` pattern exactly. Follow the protocol-through-init injection pattern from `ARCHITECTURE.md` (BalanceManager never imports concrete `RpcApiProvider` or `MainStorage`).

### Phase 2: SyncManager Orchestration

- [x] **Task 2: Add IBalanceManagerDelegate protocol and ISyncManagerDelegate protocol**
  Files: `Sources/SolanaKit/Core/Protocols.swift`
  Add two new delegate protocols to `Protocols.swift`:
  - **`IBalanceManagerDelegate: AnyObject`** with methods:
    - `func didUpdate(balance: Decimal)` — called when the SOL balance changes
    - `func didUpdate(balanceSyncState: SyncState)` — called when balance sync state changes
  - **`ISyncManagerDelegate: AnyObject`** with methods:
    - `func didUpdate(balance: Decimal)`
    - `func didUpdate(balanceSyncState: SyncState)`
    - `func didUpdate(lastBlockHeight: Int64)`
  These mirror the Android `IBalanceListener` and `ISyncListener` interfaces. Place them in the existing protocol sections, following the naming pattern of `IApiSyncerDelegate` already in the file.

- [x] **Task 3: Create SyncManager**
  Files: `Sources/SolanaKit/Core/SyncManager.swift`
  Create `SyncManager` as an internal `class` that conforms to `IApiSyncerDelegate` and `IBalanceManagerDelegate`:
  - **Dependencies** (injected via init): `apiSyncer: ApiSyncer`, `balanceManager: BalanceManager`
  - **`weak var delegate: ISyncManagerDelegate?`**
  - **`var balanceSyncState: SyncState`** — read from `balanceManager.syncState`
  - **`IApiSyncerDelegate` conformance**:
    - `didUpdateSyncerState(_ state: SyncerState)`: when `.notReady(error:)`, call `balanceManager.stop(error: error)`. When `.ready`, do nothing (sync is triggered by block height ticks, not state changes).
    - `didUpdateLastBlockHeight(_ lastBlockHeight: Int64)`: forward `delegate?.didUpdate(lastBlockHeight: lastBlockHeight)`, then launch `Task { await balanceManager.sync() }` — this is the primary trigger for balance sync (matches Android `SyncManager.didUpdateLastBlockHeight`).
  - **`IBalanceManagerDelegate` conformance**:
    - `didUpdate(balance:)`: forward to `delegate?.didUpdate(balance:)`.
    - `didUpdate(balanceSyncState:)`: forward to `delegate?.didUpdate(balanceSyncState:)`.
  - **`func refresh()`**: if `apiSyncer.state` is not `.ready`, call `apiSyncer.stop()` then `apiSyncer.start()` to restart the polling loop. Otherwise, launch `Task { await balanceManager.sync() }` directly.
  - Minimal implementation — only balance-related wiring for this milestone. `TokenAccountManager` and `TransactionSyncer` will be added in later milestones (3.2, 3.4, 3.7).

- [x] **Task 4: Wire BalanceManager delegate callbacks to Combine subjects**
  Files: `Sources/SolanaKit/Core/BalanceManager.swift`
  Add a `weak var delegate: IBalanceManagerDelegate?` property to `BalanceManager`. Update:
  - In the `syncState` `didSet`: after sending to `syncStateSubject`, also call `delegate?.didUpdate(balanceSyncState: syncState)`.
  - In `handleBalance(_:)`: after sending to `balanceSubject`, also call `delegate?.didUpdate(balance: newBalance)`.
  This enables `SyncManager` to receive callbacks and forward them to `Kit`.

### Phase 3: Kit Wiring

- [x] **Task 5: Wire everything in Kit**
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Update `Kit` to integrate `BalanceManager` and `SyncManager`:
  - **Add private properties**: `balanceManager: BalanceManager`, `syncManager: SyncManager`.
  - **Add Combine subjects** (private):
    - `balanceSubject = CurrentValueSubject<Decimal, Never>(0)`
    - `syncStateSubject = CurrentValueSubject<SyncState, Never>(.notSynced(error: SyncError.notStarted))`
    - `lastBlockHeightSubject = CurrentValueSubject<Int64, Never>(0)`
  - **Add public publishers**:
    - `public var balancePublisher: AnyPublisher<Decimal, Never>` — erases `balanceSubject`
    - `public var syncStatePublisher: AnyPublisher<SyncState, Never>` — erases `syncStateSubject`
    - `public var lastBlockHeightPublisher: AnyPublisher<Int64, Never>` — erases `lastBlockHeightSubject`
  - **Add public accessors**:
    - `public var balance: Decimal { balanceSubject.value }`
    - `public var syncState: SyncState { syncStateSubject.value }`
    - `public var lastBlockHeight: Int64 { lastBlockHeightSubject.value }`
  - **Conform `Kit` to `ISyncManagerDelegate`** (extension at bottom of file):
    - `didUpdate(balance:)` → `balanceSubject.send(balance)` on main queue
    - `didUpdate(balanceSyncState:)` → `syncStateSubject.send(state)` on main queue
    - `didUpdate(lastBlockHeight:)` → `lastBlockHeightSubject.send(height)` on main queue
  - **Update `Kit.instance()` factory**:
    1. Create `BalanceManager(address:rpcApiProvider:storage:balanceSubject:syncStateSubject:)` — pass `rpcApiProvider` (conforms to `IRpcApiProvider`), `mainStorage` (conforms to `IMainStorage`), and the two subjects.
    2. Create `SyncManager(apiSyncer:balanceManager:)`.
    3. Set `apiSyncer.delegate = syncManager`.
    4. Set `balanceManager.delegate = syncManager`.
    5. Set `syncManager.delegate = kit` (post-init assignment, same pattern as Android).
    6. Update `Kit.init` to accept the new subsystems.
  - **Update lifecycle methods**:
    - `start()`: no change needed — `apiSyncer.start()` triggers `didUpdateLastBlockHeight` via delegate, which triggers `balanceManager.sync()`.
    - `refresh()`: call `syncManager.refresh()` (remove the TODO comment).
  - **Initialize `lastBlockHeightSubject`** with `apiSyncer.lastBlockHeight ?? 0` in the factory so the subject has the persisted value before any network call.
  - Remove all milestone-3.1-related TODO comments that are now resolved.
