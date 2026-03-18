## Code Review Summary

**Files Reviewed:** 4
**Risk Level:** 🟢 Low

### Files

| File | Role |
|------|------|
| `Sources/SolanaKit/Core/BalanceManager.swift` | SOL balance fetch, cache, sync state |
| `Sources/SolanaKit/Core/SyncManager.swift` | Orchestrator wiring ApiSyncer → BalanceManager → Kit |
| `Sources/SolanaKit/Core/Protocols.swift` | `IBalanceManagerDelegate`, `ISyncManagerDelegate` |
| `Sources/SolanaKit/Core/Kit.swift` | Factory wiring, Combine publishers, `ISyncManagerDelegate` conformance |

### Context Gates

- **ARCHITECTURE.md** — `WARN`: Plan Task 1 specified `CurrentValueSubject` injection into `BalanceManager`; implementation uses delegate-only pattern instead. This is a valid design evolution that aligns better with the existing `IApiSyncerDelegate` pattern and avoids managers holding references to subjects owned by `Kit`. No violation of layer rules — `BalanceManager` depends only on `IRpcApiProvider` and `IMainStorage` protocols. ✓
- **RULES.md** — File does not exist. `WARN` (non-blocking).
- **ROADMAP.md** — Milestone 3.1 is checked complete. ✓

### Critical Issues

None.

### Suggestions

None — the implementation is clean, follows Android reference behaviour faithfully, and adheres to the architecture conventions.

### Positive Notes

1. **Faithful Android port**: The `BalanceManager` logic (in-flight guard, deduplication, `handleBalance` split, `stop()` semantics) mirrors `BalanceManager.kt` almost line-for-line. The `CancellationError` handling in `sync()` is a good Swift-specific addition that Android doesn't need (Kotlin structured concurrency handles cancellation differently).

2. **Clean delegate chain**: `BalanceManager → SyncManager → Kit → Combine subjects` is well-structured. Each layer has a single responsibility: BalanceManager fetches and caches, SyncManager routes, Kit publishes. Weak delegates prevent retain cycles.

3. **Init-time storage restore**: `BalanceManager.init` restores the persisted balance from `IMainStorage`, and `Kit.instance()` seeds `balanceSubject` from `balanceManager.balance ?? 0`. This means `Kit.balance` returns the correct value immediately after construction, before any RPC call — matching Android behavior and providing good UX.

4. **Proper `syncState` didSet guard**: The `guard syncState != oldValue` check in `BalanceManager` prevents duplicate delegate notifications. The `SyncState.Equatable` conformance handles error comparison via string description — pragmatic and consistent with `SyncerState.Equatable`.

5. **Main-queue dispatch discipline**: All delegate callbacks that flow to Combine subjects are dispatched on `DispatchQueue.main`, satisfying the architecture's "main thread for publishers" principle.

6. **Protocol-first design**: `BalanceManager` accepts `IRpcApiProvider` and `IMainStorage` — never concrete types. Testable by design.

REVIEW_PASS
