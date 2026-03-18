# Patch: 09-2-3-connectionmanager — Review Round 1

**Source review:** `.ai-factory/reviews/09-2-3-connectionmanager-review-1.md`

---

## Fix 1: Add `deinit` to cancel the `NWPathMonitor`

**File:** `Sources/SolanaKit/Core/ConnectionManager.swift`

**Problem:** `NWPathMonitor` retains itself internally once `start(queue:)` is called. If `ConnectionManager` is deallocated without an explicit `stop()`, the monitor continues running as an orphaned system resource. The `[weak self]` handler becomes a no-op but the monitor is never released. `ApiSyncer` already follows this pattern with `deinit { stop() }`.

**Fix:** Add a `deinit` that cancels the monitor.

**Before (lines 13–18):**
```swift
final class ConnectionManager {
    private var monitor: NWPathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.horizontalsystems.solana-kit.connection-manager")

    @DistinctPublished private(set) var isConnected: Bool = false
}
```

**After:**
```swift
final class ConnectionManager {
    private var monitor: NWPathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.horizontalsystems.solana-kit.connection-manager")

    @DistinctPublished private(set) var isConnected: Bool = false

    deinit {
        monitor.cancel()
    }
}
```

---

## Fix 2: Cancel the previous monitor at the top of `start()`

**File:** `Sources/SolanaKit/Core/ConnectionManager.swift`

**Problem:** `start()` creates a new `NWPathMonitor` and replaces the stored reference, but the previously started monitor is never cancelled. Since `NWPathMonitor` retains itself while running, the old instance stays alive — both monitors fire `pathUpdateHandler` simultaneously, causing redundant and potentially conflicting updates to `isConnected`. This applies whenever `start()` is called without a preceding `stop()` (e.g. `stop()` → `start()` restart cycles, or accidental double-start).

**Fix:** Call `monitor.cancel()` before creating the replacement. Calling `cancel()` on an already-cancelled or never-started monitor is a no-op, so this is safe in all cases.

**Before (lines 27–38):**
```swift
    func start() {
        // NWPathMonitor cannot be restarted after cancel — create a fresh instance each time.
        monitor = NWPathMonitor()

        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isConnected = connected
            }
        }

        monitor.start(queue: monitorQueue)
    }
```

**After:**
```swift
    func start() {
        // Cancel the previous monitor if still running (NWPathMonitor retains itself once started).
        monitor.cancel()

        monitor = NWPathMonitor()

        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isConnected = connected
            }
        }

        monitor.start(queue: monitorQueue)
    }
```

---

## Combined final state

After both fixes, `ConnectionManager.swift` should read:

```swift
import Combine
import Foundation
import HsExtensions
import Network

/// Monitors network reachability using `NWPathMonitor` and exposes a Combine publisher.
///
/// Only fires when the connected state actually changes (via `@DistinctPublished`),
/// matching Android's `if (oldValue != isConnected) { listener?.onConnectionChange() }` behaviour.
///
/// Note: `stop()` cancels the underlying `NWPathMonitor` — NWPathMonitor cannot be restarted
/// after cancellation. Call `start()` again to create a fresh monitor.
final class ConnectionManager {
    private var monitor: NWPathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.horizontalsystems.solana-kit.connection-manager")

    @DistinctPublished private(set) var isConnected: Bool = false

    deinit {
        monitor.cancel()
    }
}

// MARK: - IConnectionManager

extension ConnectionManager: IConnectionManager {
    var isConnectedPublisher: AnyPublisher<Bool, Never> {
        $isConnected
    }

    func start() {
        // Cancel the previous monitor if still running (NWPathMonitor retains itself once started).
        monitor.cancel()

        monitor = NWPathMonitor()

        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isConnected = connected
            }
        }

        monitor.start(queue: monitorQueue)
    }

    func stop() {
        monitor.cancel()
    }
}
```
