# Plan: 2.3 ConnectionManager

## Context

Implement `ConnectionManager` — an `NWPathMonitor`-based network reachability observer that exposes a synchronous `isConnected` property and a Combine publisher. It will be consumed by `ApiSyncer` (milestone 2.4) to gate sync timers: start on network up, stop on network down.

**Design note:** The project docs specify `NWPathMonitor` (Network.framework) rather than reusing `HsToolKit.ReachabilityManager` (Alamofire-backed). This is a deliberate choice for the Solana kit. However, the public API shape mirrors EvmKit's `ReachabilityManager` — a `@DistinctPublished` bool property with a projected `AnyPublisher<Bool, Never>` — so that `ApiSyncer` can subscribe identically to the EvmKit pattern.

**Key references:**
- Android source: `solana-kit-android/.../network/ConnectionManager.kt` — wraps `ConnectivityManager`, fires `Listener.onConnectionChange()` only on actual state flip
- EvmKit pattern: `ReachabilityManager` uses `@DistinctPublished` from `HsExtensions` — publishes `Bool` changes that `ApiRpcSyncer` sinks
- EvmKit `ApiRpcSyncer.swift` lines 33-37 — subscribes via `reachabilityManager.$isReachable.sink { ... }`

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Implementation

- [x] **Task 1: Add `ConnectionManager` class**
  Files: `Sources/SolanaKit/Core/ConnectionManager.swift`
  Create `ConnectionManager` in the Core layer. Implementation details:
  - `import Network`, `import Combine`, `import HsExtensions`
  - Internal class (not `public` — only `Kit` and `Signer` are public per architecture rules)
  - Property `@DistinctPublished private(set) var isConnected: Bool = false` — provides `$isConnected` as `AnyPublisher<Bool, Never>` that only fires on distinct changes (mirrors EvmKit's `ReachabilityManager.isReachable`)
  - Private `NWPathMonitor` instance and a dedicated `DispatchQueue` for the monitor (`DispatchQueue(label: "io.horizontalsystems.solana-kit.connection-manager")`)
  - `func start()` — set `pathUpdateHandler` on the monitor to update `isConnected` on `DispatchQueue.main` based on `path.status == .satisfied`, then call `monitor.start(queue:)`. Read initial status immediately from the first callback.
  - `func stop()` — call `monitor.cancel()`. After cancellation, `NWPathMonitor` cannot be restarted, so create a new monitor instance in `start()` if reuse is needed (or document that `stop()` is terminal like Android's `unregisterNetworkCallback`)
  - Match Android's distinct-change behavior: `@DistinctPublished` already handles this — only fires when value actually changes, same as Android's `if (oldValue != isConnected) { listener?.onConnectionChange() }`

- [x] **Task 2: Add `IConnectionManager` protocol to Protocols.swift**
  Files: `Sources/SolanaKit/Core/Protocols.swift`
  Add a protocol so that `ApiSyncer` (future milestone) can depend on an abstraction rather than the concrete `ConnectionManager`. This follows the architecture rule: Core depends on protocols, never concrete infra types.
  ```swift
  protocol IConnectionManager {
      var isConnected: Bool { get }
      var isConnectedPublisher: AnyPublisher<Bool, Never> { get }
  }
  ```
  Then conform `ConnectionManager` to `IConnectionManager` in `ConnectionManager.swift`, mapping `isConnectedPublisher` to `$isConnected`.

- [x] **Task 3: Wire `ConnectionManager` into `Kit.instance()` (placeholder)**
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Since `Kit.swift` does not exist yet, create a minimal stub file that documents where `ConnectionManager` will be instantiated. Add a `// TODO: [milestone 3.1]` comment showing the intended wiring:
  ```swift
  // let connectionManager = ConnectionManager()
  // let apiSyncer = ApiSyncer(..., connectionManager: connectionManager)
  ```
  If `Kit.swift` already exists by the time this task runs, add `ConnectionManager` as a stored property and instantiate it in `Kit.instance()`. Call `connectionManager.start()` from `Kit.start()` and `connectionManager.stop()` from `Kit.stop()`.
