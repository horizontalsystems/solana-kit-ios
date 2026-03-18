# Plan: 2.4 ApiSyncer

## Context

Implement `ApiSyncer` — the timer-based block height polling loop that drives all downstream sync subsystems. It polls `getBlockHeight` via `IRpcApiProvider` on a configurable interval from `RpcSource.syncInterval`, reacts to network reachability changes via `IConnectionManager`, and notifies its delegate (future `SyncManager`) on every tick. Follows the EvmKit `ApiRpcSyncer` pattern closely, adapted for Solana-specific RPC and the Android `ApiSyncer.kt` behaviour.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Types & Protocols

- [x] **Task 1: Add `SyncerState` enum and `IApiSyncerDelegate` protocol to Protocols.swift**
  Files: `Sources/SolanaKit/Core/Protocols.swift`
  Add two new declarations to the existing `Protocols.swift`:

  1. **`SyncerState`** — internal enum (not public), separate from the public `SyncState`. Mirrors Android's `SyncerState` sealed class and EvmKit's `SyncerState`. Three cases: `.preparing`, `.ready`, `.notReady(error: Error)`. Conform to `Equatable` (compare errors via string description, same pattern as `SyncState`). This represents the API-layer readiness, not the per-subsystem sync progress.

  2. **`IApiSyncerDelegate`** — protocol with two methods:
     - `func didUpdateSyncerState(_ state: SyncerState)` — called when syncer state transitions (only on distinct changes, matching Android's `if (value != field)` guard)
     - `func didUpdateLastBlockHeight(_ lastBlockHeight: Int64)` — called on every poll tick (even if block height is unchanged — this is what drives `SyncManager` to trigger balance/token/transaction syncs). The `Int64` type matches the existing `IRpcApiProvider.getBlockHeight()` return type and `IMainStorage.save(lastBlockHeight:)` parameter type.

### Phase 2: ApiSyncer Implementation

- [x] **Task 2: Create `ApiSyncer.swift`** (depends on Task 1)
  Files: `Sources/SolanaKit/Api/ApiSyncer.swift`
  Create the `ApiSyncer` class in `Api/` (same directory as `RpcApiProvider.swift`), following both the Android `ApiSyncer.kt` and EvmKit's `ApiRpcSyncer.swift` patterns. The class is `internal` (not public — only `Kit` and `Signer` are public per architecture rules).

  **Dependencies (all injected via init):**
  - `rpcApiProvider: IRpcApiProvider` — for `getBlockHeight()` RPC calls
  - `connectionManager: IConnectionManager` — for reachability state and publisher
  - `storage: IMainStorage` — for persisting and restoring `lastBlockHeight`
  - `syncInterval: TimeInterval` — poll interval in seconds (from `RpcSource.syncInterval`)

  **Stored properties:**
  - `weak var delegate: IApiSyncerDelegate?` — set externally (by future `SyncManager`)
  - `private(set) var state: SyncerState = .notReady(error: SyncError.notStarted)` — fires delegate on distinct changes (use `didSet` with `oldValue` equality check, same pattern as EvmKit line 20-26)
  - `private(set) var lastBlockHeight: Int64?` — pre-populated from `storage.lastBlockHeight()` at init time (matches Android line 60)
  - `private var isStarted: Bool = false`
  - `private var isPaused: Bool = false` — supports `pause()`/`resume()` (Android has this; EvmKit doesn't but the milestone requires it)
  - `private var timer: Timer?` — repeating `Timer` scheduled on main RunLoop (EvmKit pattern)
  - `private var tasks = Set<AnyTask>()` — holds in-flight `Task` references via HsExtensions `AnyTask` (same pattern as EvmKit `ApiRpcSyncer`)
  - `private var cancellables = Set<AnyCancellable>()` — holds Combine subscriptions

  **Computed property:**
  - `var source: String` — returns `"API \(rpcApiProvider.source)"` (matches both Android and EvmKit)

  **Init:**
  - Store all dependencies
  - Load `lastBlockHeight` from `storage.lastBlockHeight()`
  - Subscribe to `connectionManager.isConnectedPublisher` via `.sink { [weak self] connected in self?.handleUpdate(reachable: connected) }` stored in `cancellables` (matches EvmKit lines 33-37)
  - Register for `UIApplication.didEnterBackgroundNotification` and `UIApplication.willEnterForegroundNotification` via `NotificationCenter` (EvmKit lines 39-40). On background: invalidate timer. On foreground: restart timer only if `isStarted` (EvmKit lines 47-57)

  **Deinit:** call `stop()` (EvmKit line 43-45)

  **Lifecycle methods:**
  - `start()` — set `isStarted = true`, call `handleUpdate(reachable: connectionManager.isConnected)` to kick off based on current reachability (matches both Android line 63-68 and EvmKit line 97-100)
  - `stop()` — set `isStarted = false`, set `isPaused = false`, clear `tasks = Set()`, set `state = .notReady(error: SyncError.notStarted)`, invalidate timer (matches EvmKit lines 103-111, plus Android's `isPaused = false` and `connectionManager.stop()` omitted here because `ConnectionManager` lifecycle is owned by `Kit`)
  - `pause()` — set `isPaused = true`, invalidate timer and stop it (matches Android lines 83-86)
  - `resume()` — set `isPaused = false`, restart timer only if `isStarted && connectionManager.isConnected` (matches Android lines 87-91)

  **Private methods:**
  - `startTimer()` — invalidate existing timer, then on `DispatchQueue.main.async` create a `Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true)` that calls `onFireTimer()`, set `tolerance = 0.5` (exact EvmKit pattern, lines 66-75). Also call `onFireTimer()` immediately after scheduling to get the first sync without waiting for the interval (matching Android's `emit(Unit)` before `delay` pattern, line 131-132)
  - `stopTimer()` — `timer?.invalidate(); timer = nil`
  - `onFireTimer()` — launch a `Task { [weak self, rpcApiProvider] in ... }.store(in: &tasks)` (EvmKit pattern, lines 59-63). Inside the task: call `try await rpcApiProvider.getBlockHeight()`, then call `self?.handleBlockHeight(blockHeight)`. On error (non-cancellation): set `state = .notReady(error: error)` (Android lines 93-101)
  - `handleBlockHeight(_ blockHeight: Int64)` — if `self.lastBlockHeight != blockHeight`, update `self.lastBlockHeight` and call `try? storage.save(lastBlockHeight: blockHeight)` (persist, guarded by equality check — Android lines 104-108). Then **unconditionally** call `delegate?.didUpdateLastBlockHeight(blockHeight)` — this fires every tick even if unchanged, which is what drives downstream sync (Android line 110)
  - `handleUpdate(reachable: Bool)` — guard `isStarted` else return. If reachable: set `state = .ready`, if not `isPaused` then `startTimer()`. If not reachable: set `state = .notReady(error: SyncError.noNetworkConnection)`, call `stopTimer()` (combined Android lines 113-125 and EvmKit lines 77-89, plus the `isPaused` guard from Android line 118)

  **Import list:** `Foundation`, `Combine`, `HsExtensions` (for `AnyTask` and `Set<AnyTask>`), `UIKit` (for `UIApplication` notifications)

### Phase 3: Kit Wiring

- [x] **Task 3: Wire `ApiSyncer` into `Kit.swift`** (depends on Task 2)
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Update the existing `Kit.swift` to create and own an `ApiSyncer` instance:

  1. **Add stored property:** `private let apiSyncer: ApiSyncer` (remove the `// TODO: [milestone 2.4]` comment)
  2. **Update init:** accept `apiSyncer: ApiSyncer` parameter alongside `connectionManager`
  3. **Update factory `Kit.instance(...)`:**
     - Create `RpcApiProvider` from `rpcSource` (it needs the URL and optional auth header — use `RpcApiProvider(networkManager: NetworkManager(logger: nil), rpcSource: rpcSource)` or however the existing `RpcApiProvider.init` works). Check the existing init signature.
     - Create `MainStorage` via `try MainStorage(walletId: walletId)` (already exists)
     - Create `ApiSyncer(rpcApiProvider: rpcApiProvider, connectionManager: connectionManager, storage: mainStorage, syncInterval: rpcSource.syncInterval)`
     - Pass `apiSyncer` to `Kit(connectionManager:apiSyncer:)`
  4. **Update lifecycle methods:**
     - `start()`: add `apiSyncer.start()` after `connectionManager.start()`
     - `stop()`: add `apiSyncer.stop()` before or after `connectionManager.stop()`
     - `refresh()`: leave as-is (refresh is orchestrated by `SyncManager` in milestone 3.7, which will call `apiSyncer.stop()` then `apiSyncer.start()` when not ready, matching Android's `SyncManager.refresh()`)
  5. Add `pause()` and `resume()` public methods on `Kit` that delegate to `apiSyncer.pause()` / `apiSyncer.resume()` (these are in the target public API per CLAUDE.md)

- [x] **Task 4: Verify `RpcApiProvider` instantiation in Kit factory** (depends on Task 3)
  Files: `Sources/SolanaKit/Api/RpcApiProvider.swift`, `Sources/SolanaKit/Core/Kit.swift`
  Read `RpcApiProvider.init` to confirm its exact parameter list (it takes `NetworkManager` + `rpcSource` or URL + auth). Ensure `Kit.instance()` creates it correctly. If `RpcApiProvider` expects raw URL + headers, extract those from `rpcSource`. Add a `// TODO: [milestone 3.1]` comment in the factory noting that `apiSyncer.delegate` will be set to `SyncManager` once that milestone is implemented. For now, `delegate` remains `nil` — the timer runs and persists block height to storage, but nobody receives the callbacks yet.

## Commit Plan
- **Commit 1** (after tasks 1-2): "Add SyncerState, IApiSyncerDelegate protocol, and ApiSyncer timer-based block height poller"
- **Commit 2** (after tasks 3-4): "Wire ApiSyncer into Kit factory and lifecycle"
