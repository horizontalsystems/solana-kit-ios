# Review: 2.4 ApiSyncer — Review 1

## Files Reviewed
- `Sources/SolanaKit/Core/Protocols.swift` (modified — added `SyncerState`, `IApiSyncerDelegate`)
- `Sources/SolanaKit/Api/ApiSyncer.swift` (new)
- `Sources/SolanaKit/Core/Kit.swift` (modified — wiring + lifecycle)

## Build Status
Compiles successfully for iOS. Pre-existing Sendable warnings from `RpcApiProvider` (not introduced by this milestone).

---

## Issues

### BUG: `onEnterForeground` ignores `isPaused` flag

**File:** `Sources/SolanaKit/Api/ApiSyncer.swift:105-108`

```swift
@objc private func onEnterForeground() {
    guard isStarted else { return }
    startTimer()  // ← missing isPaused check
}
```

If a caller invokes `pause()` and then the app backgrounds and foregrounds, the timer silently restarts — violating the pause contract. The `handleUpdate(reachable:)` method correctly checks `!isPaused` before calling `startTimer()` (line 163), but the foreground handler does not.

This is an iOS-specific concern (Android doesn't have app lifecycle callbacks; EvmKit has the same foreground handler but doesn't have `pause()`/`resume()` at all, so no conflict there).

**Fix:** Add `guard !isPaused else { return }` after the `isStarted` check:

```swift
@objc private func onEnterForeground() {
    guard isStarted, !isPaused else { return }
    startTimer()
}
```

### MINOR: Potential zombie timer from `startTimer()` async dispatch

**File:** `Sources/SolanaKit/Api/ApiSyncer.swift:112-126`

`startTimer()` calls `stopTimer()` synchronously (line 113) then creates the new timer inside `DispatchQueue.main.async` (line 116). If `stop()` is called between the synchronous `stopTimer()` and the async block executing, the async block will still run and create a timer that nothing will invalidate.

Sequence: `start()` → `stop()` (same run-loop turn) → async block fires → orphan timer.

In practice this is low-risk (the timer closure captures `[weak self]` so it stops when the `ApiSyncer` is deallocated, and the worst outcome is one extra RPC call). This matches EvmKit's `ApiRpcSyncer` pattern exactly. Noting for awareness — not blocking.

---

## Correctness Checks (all pass)

| Check | Result |
|-------|--------|
| `SyncerState` cases match Android sealed class | `.preparing`, `.ready`, `.notReady(error:)` — correct |
| `SyncerState: Equatable` error comparison via string | Matches `SyncState` pattern |
| `IApiSyncerDelegate` methods match Android listener | `didUpdateSyncerState` + `didUpdateLastBlockHeight` — correct |
| `state` didSet fires only on distinct changes | Uses `oldValue` equality check — correct |
| `lastBlockHeight` pre-populated from storage at init | Line 70 — correct |
| `handleBlockHeight` persists only on change, notifies unconditionally | Lines 149-154 — correct (matches Android) |
| `handleUpdate(reachable:)` respects `isStarted` and `isPaused` | Lines 157-170 — correct |
| `start()` delegates to `handleUpdate(reachable:)` | Line 177 — correct |
| `stop()` clears all state and invalidates timer | Lines 180-186 — correct |
| `pause()` / `resume()` match Android behaviour | Lines 190-201 — correct |
| Combine subscription uses `[weak self]` | Line 74 — correct |
| NotificationCenter observers registered | Lines 81-92 — correct |
| `deinit` calls `stop()` | Line 96 — correct |
| Kit factory creates `RpcApiProvider` with correct init signature | `(networkManager:url:auth:)` matches `RpcApiProvider.init` — correct |
| Kit factory passes `rpcSource.syncInterval` | Line 54 — correct |
| Kit lifecycle calls `apiSyncer.start()` / `stop()` | Lines 71, 77 — correct |
| Kit exposes `pause()` / `resume()` as public API | Lines 88-95 — correct |
| `auth: nil` is appropriate | `RpcSource` has no auth field — correct for now |
| TODO comment for milestone 3.1 delegate wiring | Line 57 — present |

---

## Verdict

One real bug (`onEnterForeground` ignoring `isPaused`). Fix it and this is good to go.

REVIEW_NEEDS_FIX
