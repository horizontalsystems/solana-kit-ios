## Code Review — Round 2

**Reviewing:** patch from review round 1 applied to `Sources/SolanaKit/Api/ApiSyncer.swift`
**Files changed:** `Sources/SolanaKit/Api/ApiSyncer.swift` (the only source change)
**Build:** iOS Simulator — BUILD SUCCEEDED

### Change Applied

One fix from the round-1 review:

**`state = .ready` at the top of `handleBlockHeight`** (lines 148–151) — Recovers the syncer state after a transient RPC error. Previously, a single failed `getBlockHeight()` call set `state = .notReady(error:)` and the state stayed there indefinitely even when subsequent ticks succeeded, because only a reachability change could reset it.

### Verification

- **Normal tick (state already `.ready`):** `state = .ready` fires `didSet` → `state != oldValue` is `false` → delegate NOT called → no-op. Correct.
- **Recovery tick (state was `.notReady`):** `state = .ready` fires `didSet` → `state != oldValue` is `true` → `delegate?.didUpdateSyncerState(.ready)` called → `SyncManager` handles `.ready` with `break` (no-op, line 152). Then `didUpdateLastBlockHeight` fires and triggers the actual sync. Correct.
- **Error tick (unchanged):** `onFireTimer` catch sets `state = .notReady(error:)` → delegate called → `SyncManager` stops managers with error. Correct.
- **`SyncManager.refresh()` path:** Now correctly takes the direct-sync branch (`case .ready`) after recovery instead of the heavier restart path (`stop()` + `start()`). Correct.
- No other lines changed — `Protocols.swift` and `Kit.swift` are untouched.
- Comment accurately explains the intent and the safety guarantee (didSet dedup).

### Issues

None.

REVIEW_PASS
