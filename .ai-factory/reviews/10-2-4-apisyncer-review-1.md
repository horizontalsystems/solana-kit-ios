## Code Review Summary

**Files Reviewed:** 3
- `Sources/SolanaKit/Core/Protocols.swift` (modified — added `SyncerState`, `IApiSyncerDelegate`)
- `Sources/SolanaKit/Api/ApiSyncer.swift` (new — 203 lines)
- `Sources/SolanaKit/Core/Kit.swift` (modified — wiring + lifecycle)

**Build Status:** BUILD SUCCEEDED (iOS Simulator). Pre-existing Sendable warnings only.
**Risk Level:** 🟢 Low

### Context Gates

- **ARCHITECTURE.md:** PASS — `ApiSyncer` is `internal`, lives in `Api/`, depends on protocols (`IRpcApiProvider`, `IConnectionManager`, `IMainStorage`) not concrete types. Instantiated only in `Kit.instance()`. All layer rules satisfied.
- **RULES.md:** WARN — file does not exist; no project-specific rules to check.
- **ROADMAP.md:** PASS — milestone 2.4 ("ApiSyncer") is listed and marked `[x]` complete. Implementation matches the milestone description: timer-based block height polling, configurable interval, start/stop/pause/resume, fires delegate on new block height.
- **skill-context (aif-review/SKILL.md):** WARN — file does not exist; no project-specific review rules.

### Critical Issues

None.

### Suggestions

1. **Missing state recovery after transient RPC error**
   File: `Sources/SolanaKit/Api/ApiSyncer.swift`, lines 133-143

   When `onFireTimer()` fails, `state` is set to `.notReady(error: error)` (line 140). On the next successful tick, `handleBlockHeight` notifies the delegate but never resets `state` back to `.ready`. The state remains `.notReady` until a reachability change triggers `handleUpdate(reachable: true)`.

   This means `SyncManager.refresh()` takes the restart path (`stop()` + `start()`) instead of the direct-sync path even when the RPC endpoint is responding normally. Downstream syncs still happen via the heartbeat, so this is not a functional failure — but the state is inaccurate.

   The Android reference has the same limitation. A one-line fix restores accuracy:

   ```swift
   private func handleBlockHeight(_ blockHeight: Int64) {
       state = .ready  // recover from transient error
       if lastBlockHeight != blockHeight {
           lastBlockHeight = blockHeight
           try? storage.save(lastBlockHeight: blockHeight)
       }
       delegate?.didUpdateLastBlockHeight(blockHeight)
   }
   ```

   This is safe because `state`'s `didSet` only fires the delegate on distinct changes, so repeated `.ready` → `.ready` transitions are no-ops.

### Positive Notes

- Faithful port of Android `ApiSyncer.kt` with correct iOS lifecycle handling (background/foreground notifications from EvmKit pattern).
- `isPaused` flag is respected in all code paths: `handleUpdate(reachable:)`, `onEnterForeground()`, and `resume()`.
- `[weak self]` used consistently in all closures — no retain cycles between `ApiSyncer`, its Combine subscriptions, timer, or Tasks.
- `deinit { stop() }` ensures timer and task cleanup even if the caller forgets to call `stop()`.
- Correct lifecycle ordering in Kit: `connectionManager.start()` before `apiSyncer.start()` (ensures reachability is being monitored before the syncer queries it); `apiSyncer.stop()` before `connectionManager.stop()` (avoids spurious reachability state change triggering work in a stopping syncer).
- `handleBlockHeight` correctly persists only on change but notifies unconditionally — matching Android's heartbeat semantic that drives all downstream syncs.
- `SyncerState` Equatable conformance uses string-based error comparison, matching the established `SyncState` pattern.
- Well-placed TODO comment for milestone 3.1 delegate wiring.
