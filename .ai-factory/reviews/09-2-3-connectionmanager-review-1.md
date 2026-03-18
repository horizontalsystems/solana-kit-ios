# Review: 2.3 ConnectionManager

**Scope:** `ConnectionManager.swift`, `Kit.swift`, `Protocols.swift` changes
**Build status:** Compiles successfully (iOS target, xcodebuild)

---

## ConnectionManager.swift

### Issue 1 — `stop()` does not reset `isConnected` to `false` (minor)

Android's `ConnectionManager.stop()` unregisters the callback, which means no further updates arrive and the state is implicitly stale. Here, after `stop()`, `isConnected` could remain `true` even though the monitor is cancelled and no longer reporting. If `ApiSyncer` (milestone 2.4) checks `isConnected` after `stop()` and before the next `start()`, it would see a stale `true`.

**Recommendation:** Set `isConnected = false` inside `stop()` so the state is clean between lifecycle cycles. This is optional — `ApiSyncer` typically has its own `isStarted` guard (as in EvmKit's `ApiRpcSyncer`) — but it makes `ConnectionManager` a more honest state machine.

**Severity:** Minor / defensive. Not a bug in current usage since `Kit.stop()` stops everything, but could surprise a future consumer.

### Issue 2 — No `deinit` cleanup (informational)

If a `ConnectionManager` is deallocated without `stop()` being called, the `NWPathMonitor` will keep running on its queue. In practice this is fine because `Kit` owns `ConnectionManager` and calls `stop()` in `Kit.stop()`, and `NWPathMonitor` is cancelled on dealloc anyway by its own implementation. No action needed.

### Correctness: `@DistinctPublished` usage — OK

`@DistinctPublished` from `HsExtensions` projects to `AnyPublisher<Bool, Never>` via `$isConnected`. The `didSet` guard (`if oldValue != wrappedValue`) ensures only actual state changes fire downstream. This correctly mirrors both:
- Android's `if (oldValue != isConnected) { listener?.onConnectionChange() }`
- EvmKit's `ReachabilityManager.@DistinctPublished isReachable`

### Correctness: Thread safety — OK

`NWPathMonitor` delivers callbacks on `monitorQueue` (a serial queue). The handler dispatches `.isConnected` updates to `DispatchQueue.main`. `@DistinctPublished` uses a `PassthroughSubject` internally which is thread-safe for `send()` calls. The `DispatchQueue.main.async` dispatch ensures all downstream Combine subscribers receive values on the main thread, matching the architecture requirement.

### Correctness: `start()` re-creates monitor — OK

The `start()` method creates a fresh `NWPathMonitor()` before setting the handler and calling `.start(queue:)`. This correctly handles the NWPathMonitor limitation (cannot restart after cancel). The previous monitor reference is replaced, and ARC will clean it up.

---

## Protocols.swift

### `IConnectionManager` protocol — OK

The protocol includes `isConnected`, `isConnectedPublisher`, `start()`, `stop()`. This is a clean abstraction. The `start()`/`stop()` lifecycle methods are included, which matches how `Kit` calls them.

One observation: `import Combine` was added at line 8. This is fine — it was already implicitly needed for the `IRpcApiProvider` extension methods that return Combine-compatible types, but having it explicit is better.

---

## Kit.swift

### Issue 3 — `connectionManager` typed as concrete `ConnectionManager`, not `IConnectionManager` (acceptable)

`Kit.swift` line 14 declares `private let connectionManager: ConnectionManager` using the concrete type. Per the architecture rules, Kit is the composition root and the only place where concrete types are created — so this is actually the correct pattern (mirrors how EvmKit's `Kit` holds concrete `ReachabilityManager`). Managers/syncers that receive `connectionManager` as a dependency should use the `IConnectionManager` protocol type.

**No action needed** — this is correct for the composition root.

### Issue 4 — Missing `pause()` / `resume()` methods (informational)

The architecture docs mention `pause()` / `resume()` on `Kit`, and Android's `ApiSyncer` has these. `Kit.swift` currently has `start()`, `stop()`, and `refresh()` but no `pause()`/`resume()`. These are likely deferred to milestone 3.1 when `SyncManager` is wired. Not an issue for this milestone.

---

## Summary

| # | File | Issue | Severity |
|---|------|-------|----------|
| 1 | ConnectionManager.swift | `stop()` leaves `isConnected` potentially stale as `true` | Minor |
| 2 | ConnectionManager.swift | No `deinit` cleanup | Informational |
| 3 | Kit.swift | Concrete type for connectionManager (correct for composition root) | None |
| 4 | Kit.swift | Missing `pause()`/`resume()` | Informational (future milestone) |

No critical or high-severity issues found. The implementation is clean, compiles, and correctly matches both the Android source behavior and the EvmKit Combine patterns.

REVIEW_PASS
