# Review: 2.4 ApiSyncer — Review 2

## Files Reviewed
- `Sources/SolanaKit/Core/Protocols.swift` (modified — added `SyncerState`, `IApiSyncerDelegate`)
- `Sources/SolanaKit/Api/ApiSyncer.swift` (new)
- `Sources/SolanaKit/Core/Kit.swift` (modified — wiring + lifecycle)

## Build Status
Compiles successfully for iOS. Pre-existing Sendable warnings only (not introduced by this milestone).

## Review 1 Fix Verification
The `onEnterForeground` bug from review 1 is fixed. Line 106 now reads:
```swift
guard isStarted, !isPaused else { return }
```
This correctly prevents the timer from restarting after a background→foreground transition when `pause()` is active.

---

## Issues

No critical or blocking issues found.

### Previously noted (non-blocking, unchanged)

**MINOR: Potential zombie timer from `startTimer()` async dispatch** — `startTimer()` creates the timer inside `DispatchQueue.main.async` while `stopTimer()` runs synchronously. A rapid `start()`→`stop()` on the same run-loop turn could leave an orphan timer. Low-risk: the timer closure captures `[weak self]`, so the timer becomes inert once `ApiSyncer` is deallocated. Matches EvmKit's `ApiRpcSyncer` pattern exactly. Not blocking.

---

## Correctness Checks

| Check | Result |
|-------|--------|
| **Protocols.swift** | |
| `SyncerState` cases match Android sealed class | `.preparing`, `.ready`, `.notReady(error:)` — correct |
| `SyncerState: Equatable` error comparison | String-based comparison, same pattern as `SyncState` — correct |
| `IApiSyncerDelegate` methods match Android listener | `didUpdateSyncerState` + `didUpdateLastBlockHeight` — correct |
| Delegate protocol is `AnyObject` (class-bound for `weak`) | Yes — correct |
| **ApiSyncer.swift** | |
| `state` didSet fires only on distinct changes | `oldValue` equality check — correct |
| `lastBlockHeight` pre-populated from storage | Init line 70 — correct |
| Combine subscription uses `[weak self]` | Line 74 — correct |
| NotificationCenter observers registered (background + foreground) | Lines 81-92 — correct |
| `onEnterForeground` respects `isPaused` | Line 106 — **fixed** |
| `onEnterBackground` stops timer | Line 102 — correct |
| `startTimer()` fires immediately on first tick | Line 124 — correct (matches Android emit-before-delay) |
| `stopTimer()` invalidates and nils the timer | Lines 129-130 — correct |
| `onFireTimer()` captures `[weak self, rpcApiProvider]` | Line 134 — correct |
| `CancellationError` silently ignored | Line 139 — correct |
| `handleBlockHeight` persists only on change | Lines 149-151 — correct |
| `handleBlockHeight` notifies delegate unconditionally | Line 154 — correct (heartbeat) |
| `handleUpdate` guards `isStarted` | Line 158 — correct |
| `handleUpdate` guards `!isPaused` before starting timer | Line 163 — correct |
| `start()` delegates to `handleUpdate(reachable:)` | Line 177 — correct |
| `stop()` clears all state flags, tasks, and timer | Lines 180-186 — correct |
| `pause()` sets flag and stops timer | Lines 191-192 — correct |
| `resume()` checks both `isStarted` and `isConnected` | Lines 199 — correct |
| `deinit` calls `stop()` | Line 96 — correct |
| **Kit.swift** | |
| Factory creates `MainStorage` with `walletId` | Line 41 — correct |
| Factory creates `NetworkManager(logger: nil)` | Line 43 — correct |
| Factory creates `RpcApiProvider` with matching init signature | `(networkManager:url:auth:)` — correct |
| Factory passes `rpcSource.syncInterval` to `ApiSyncer` | Line 54 — correct |
| `start()` calls `connectionManager.start()` before `apiSyncer.start()` | Lines 70-71 — correct order |
| `stop()` calls `apiSyncer.stop()` before `connectionManager.stop()` | Lines 77-78 — correct order (avoids spurious reachability state change) |
| `pause()` / `resume()` exposed as public API | Lines 88-95 — correct |
| TODO for milestone 3.1 delegate wiring | Line 57 — present |

---

## Verdict

The review 1 bug is fixed. No remaining critical or blocking issues. Implementation correctly ports Android `ApiSyncer` behaviour with proper iOS lifecycle handling (EvmKit pattern).

REVIEW_PASS
