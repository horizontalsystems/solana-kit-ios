## Code Review Summary

**Files Reviewed:** 2
**Risk Level:** 🟢 Low

### Context Gates

- **ARCHITECTURE.md:** WARN — No violations. Lifecycle routing through SyncManager aligns with the documented sync lifecycle flow (`kit.start() → SyncManager.start() → ApiSyncer.start()`). Dependencies flow correctly (Kit → SyncManager → subsystems). All subsystems remain `internal`.
- **RULES.md:** N/A — file does not exist.
- **ROADMAP.md:** WARN — Milestone 3.7 is listed and marked complete. No linkage issues.

### Critical Issues

None.

### Suggestions

None.

### Positive Notes

- **Clean lifecycle encapsulation.** All lifecycle calls (`start/stop/pause/resume`) now route through `SyncManager` instead of Kit calling `ApiSyncer` directly. This matches the Android architecture and the documented sync lifecycle in `ARCHITECTURE.md`.

- **Proper double-start guard.** The `started` flag in `start()` prevents re-entrant subscription creation, matching Android's `if (started) return` pattern.

- **Correct Combine teardown.** `transactionManagerCancellable` is set to `nil` in `stop()`, properly canceling the subscription. The subscription is only created in `start()`, tying it to the lifecycle instead of the old `didSet` approach.

- **Weak self in closures.** Both the Combine sink and the `Task` inside it correctly capture `[weak self]`, preventing retain cycles through the subscription chain.

- **Thorough shutdown.** The iOS version stops `transactionSyncer` in both `stop()` and `didUpdateSyncerState(.notReady)`, which Android omits. This is an improvement — it ensures the transaction syncer's sync state properly transitions to `.notSynced` on shutdown, giving consumers accurate state.

- **Clean removal of post-init injection.** The old `var transactionSyncer: TransactionSyncer?` and `var transactionManager: TransactionManager?` with their `didSet` wiring are replaced by `private let` properties initialized in `init`. All optional chaining removed throughout. This eliminates a class of bugs where methods could be called before injection.

- **Correct Kit lifecycle order.** `start()` calls `connectionManager.start()` before `syncManager.start()` (monitor first, then sync). `stop()` calls `syncManager.stop()` before `connectionManager.stop()` (tear down sync first, then monitor). This is the correct order.

REVIEW_PASS
