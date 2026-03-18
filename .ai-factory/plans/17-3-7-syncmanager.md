# Plan: 3.7 SyncManager

## Context

Complete SyncManager as the central orchestrator by adding start/stop/pause/resume lifecycle methods, promoting optional subsystems to required dependencies, and routing Kit's lifecycle calls through SyncManager instead of directly to ApiSyncer. The existing SyncManager already implements all delegate callbacks (IApiSyncerDelegate, IBalanceManagerDelegate, ITokenAccountManagerDelegate, ITransactionSyncerDelegate) and the refresh() method — this milestone closes the remaining lifecycle gaps.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: SyncManager lifecycle completion

- [x] **Task 1: Promote optional subsystems to required init parameters**
  Files: `Sources/SolanaKit/Core/SyncManager.swift`
  Currently `transactionSyncer` and `transactionManager` are optional `var` properties set post-init from `Kit.instance()`. In Android they are constructor parameters. Refactor:
  1. Change `var transactionSyncer: TransactionSyncer?` to `private let transactionSyncer: TransactionSyncer` (required init param).
  2. Change `var transactionManager: TransactionManager?` to `private let transactionManager: TransactionManager` (required init param, remove the `didSet` block entirely — the Combine subscription will move to `start()` in Task 2).
  3. Update `init(...)` to accept all five dependencies: `apiSyncer`, `balanceManager`, `tokenAccountManager`, `transactionSyncer`, `transactionManager`.
  4. Remove all optional chaining on these properties throughout the file (`transactionSyncer?.sync()` → `transactionSyncer.sync()`, `transactionSyncer?.stop(error:)` → `transactionSyncer.stop(error:)`, `transactionSyncer?.syncState` → `transactionSyncer.syncState`, `transactionManager?.transactionsPublisher` → `transactionManager.transactionsPublisher`).
  5. Remove the `SyncError.notStarted` fallback in the `transactionsSyncState` computed property — it can now read `transactionSyncer.syncState` directly (non-optional).
  6. Keep `transactionManagerCancellable` as a private var (it will be set in `start()`).

- [x] **Task 2: Add start/stop/pause/resume lifecycle methods** (depends on Task 1)
  Files: `Sources/SolanaKit/Core/SyncManager.swift`
  Add the four lifecycle methods that mirror Android `SyncManager.start/stop` and `pause/resume`. Reference: Android `SyncManager.kt` lines 33–62.
  1. Add `private var started: Bool = false` property.
  2. `func start()` — guard `if started { return }`, set `started = true`, call `apiSyncer.start()`, subscribe to `transactionManager.transactionsPublisher` and on each emission: (a) trigger `Task { await balanceManager.sync() }` to refresh SOL balance after new transactions (mirrors Android's `transactionsFlow.collect` in `start()`), and (b) forward the batch to `delegate?.didUpdate(transactions:)`. Store the cancellable in `transactionManagerCancellable`.
  3. `func stop()` — set `started = false`, call `apiSyncer.stop()`, `balanceManager.stop()`, `tokenAccountManager.stop()`, `transactionSyncer.stop()`, cancel `transactionManagerCancellable` (set to `nil`).
  4. `func pause()` — delegate to `apiSyncer.pause()`.
  5. `func resume()` — delegate to `apiSyncer.resume()`.

- [x] **Task 3: Route Kit lifecycle through SyncManager** (depends on Task 2)
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Update Kit to use SyncManager as the single lifecycle entry point (instead of calling ApiSyncer directly). Reference: Android `SolanaKit.start/stop/refresh/pause/resume`.
  1. In `Kit.start()`: change from `apiSyncer.start()` to `syncManager.start()`. Keep `connectionManager.start()` (called separately, same as Android — ApiSyncer handles the initial not-connected state gracefully and starts polling once ConnectionManager reports connectivity).
  2. In `Kit.stop()`: change from `apiSyncer.stop()` to `syncManager.stop()`. Keep `connectionManager.stop()`.
  3. In `Kit.pause()`: change from `apiSyncer.pause()` to `syncManager.pause()`.
  4. In `Kit.resume()`: change from `apiSyncer.resume()` to `syncManager.resume()`.
  5. In `Kit.instance()` factory: update `SyncManager(...)` construction to pass all five dependencies (`apiSyncer`, `balanceManager`, `tokenAccountManager`, `transactionSyncer`, `transactionManager`). Remove the two post-init injection lines (`syncManager.transactionSyncer = transactionSyncer` and `syncManager.transactionManager = transactionManager`).
  6. Kit no longer needs to hold a direct reference to `apiSyncer` for lifecycle calls — but keep the stored property since Kit.instance() creates it and it must stay alive. Just stop calling lifecycle methods on it directly.
