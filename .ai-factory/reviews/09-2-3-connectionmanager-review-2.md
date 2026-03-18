## Code Review — Round 2

**Reviewing:** patch from review round 1 applied to `ConnectionManager.swift`
**Files changed:** `Sources/SolanaKit/Core/ConnectionManager.swift` (the only source change)
**Build:** iOS Simulator — BUILD SUCCEEDED

### Changes Applied

Two defensive fixes from the round-1 review:

1. **`deinit { monitor.cancel() }`** (lines 19–21) — Ensures the `NWPathMonitor` is cancelled if `ConnectionManager` is deallocated without an explicit `stop()`. Prevents orphaned system resources.

2. **`monitor.cancel()` at the top of `start()`** (line 33) — Cancels the previous monitor before creating a replacement, preventing dual-monitor leaks on double-start. `cancel()` is a no-op on an already-cancelled or never-started monitor, so this is safe in all paths.

### Verification

- Both fixes are minimal and surgical — no other lines changed.
- `stop()` still calls `monitor.cancel()` as before; `deinit` is a safety net, not a replacement.
- `start()` → `stop()` → `start()` cycle: first `start()` cancels the init-time monitor (never started, cancel is no-op), creates and starts a new one. `stop()` cancels it. Second `start()` cancels the already-cancelled monitor (no-op), creates a fresh one. Correct.
- Double `start()` without `stop()`: first `start()` creates monitor A. Second `start()` cancels monitor A, creates monitor B. Only B is running. Correct.
- `deinit` path: if `stop()` was already called, `monitor` is already cancelled; `deinit` calling `cancel()` again is a no-op. If `stop()` was never called, `deinit` cancels the live monitor. Correct in both cases.
- No protocol or public API changes — `Protocols.swift` and `Kit.swift` are untouched.
- Matches `ApiSyncer.deinit { stop() }` pattern already established in the codebase.

### Issues

None.

REVIEW_PASS
