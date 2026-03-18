## Code Review Summary

**Files Reviewed:** 3 (`ConnectionManager.swift`, `Protocols.swift`, `Kit.swift`)
**Risk Level:** 🟢 Low

### Context Gates

- **ARCHITECTURE.md:** PASS — `ConnectionManager` is `internal`, lives in `Core/`, protocol defined in `Protocols.swift`, concrete type instantiated only in `Kit.instance()`. All layer rules satisfied.
- **RULES.md:** WARN — file does not exist; no project-specific rules to check.
- **ROADMAP.md:** PASS — milestone 2.3 ("ConnectionManager") is listed and marked complete. Implementation matches the milestone description: NWPathMonitor-based reachability, Combine publisher, start/stop lifecycle.
- **skill-context (aif-review/SKILL.md):** WARN — file does not exist; no project-specific review rules.

### Critical Issues

None.

### Suggestions

1. **Missing `deinit` — orphaned `NWPathMonitor` if `ConnectionManager` is deallocated without `stop()`**
   File: `Sources/SolanaKit/Core/ConnectionManager.swift`

   `NWPathMonitor` retains itself internally once `start(queue:)` is called — it continues running until `cancel()` is explicitly called, regardless of whether the reference is held. If `ConnectionManager` is deallocated without `stop()`, the monitor becomes an orphan (the `[weak self]` handler becomes a no-op but the system resource is never released).

   `ApiSyncer` already has `deinit { stop() }` for its timer cleanup. `ConnectionManager` should follow the same pattern:

   ```swift
   deinit {
       monitor.cancel()
   }
   ```

2. **Double `start()` without `stop()` leaks the previous `NWPathMonitor`**
   File: `Sources/SolanaKit/Core/ConnectionManager.swift`, line 29

   `start()` creates a new `NWPathMonitor` and replaces the reference, but the previously started monitor is never cancelled. Since `NWPathMonitor` retains itself while running, the old instance stays alive — both monitors would fire `pathUpdateHandler` simultaneously, causing redundant (and potentially conflicting) updates to `isConnected`.

   In practice, `Kit` calls `start()` only once, so this is defensive. But adding `monitor.cancel()` before creating the new instance is safe and cost-free:

   ```swift
   func start() {
       monitor.cancel()               // cancel previous if still running
       monitor = NWPathMonitor()
       monitor.pathUpdateHandler = { ... }
       monitor.start(queue: monitorQueue)
   }
   ```

### Positive Notes

- Clean, minimal implementation that correctly mirrors the Android `ConnectionManager` distinct-change behaviour using `@DistinctPublished` from HsExtensions — no manual state-flip tracking needed.
- `[weak self]` in the `pathUpdateHandler` closure avoids retain cycles between `NWPathMonitor` and `ConnectionManager`.
- Updates dispatched to `DispatchQueue.main` satisfy the architecture rule that all Combine `.send()` calls happen on the main thread.
- The `IConnectionManager` protocol in `Protocols.swift` properly abstracts the dependency — `ApiSyncer` depends on the protocol, not the concrete type, enabling testability.
- Comment documenting that `NWPathMonitor` cannot be restarted after cancellation is helpful for future maintainers.
- The `start()`/`stop()` lifecycle methods are exposed through the protocol, keeping the API consistent with the rest of the sync subsystem lifecycle.
