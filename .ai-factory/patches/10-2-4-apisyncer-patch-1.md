# Patch: 10-2-4-apisyncer — Review Round 1

**Source review:** `.ai-factory/reviews/10-2-4-apisyncer-review-1.md`

---

## Fix 1: Recover `state` to `.ready` after a successful RPC response

**File:** `Sources/SolanaKit/Api/ApiSyncer.swift`

**Problem:** When `onFireTimer()` catches an RPC error, it sets `state = .notReady(error: error)` (line 140). On the next successful tick, `handleBlockHeight` is called but never resets `state` back to `.ready`. The state remains `.notReady` indefinitely — it only recovers if a reachability change fires `handleUpdate(reachable: true)`.

This causes `SyncManager.refresh()` to take the restart path (`apiSyncer.stop()` + `apiSyncer.start()`) even when the RPC endpoint is responding normally, because it checks `if case .ready = apiSyncer.state`. Downstream syncs still happen via the heartbeat so there is no data loss, but the state is inaccurate and the refresh path is heavier than necessary.

**Why this is safe:** The `state` property's `didSet` guard (`if state != oldValue`) means repeated `.ready` → `.ready` assignments are no-ops — the delegate is not notified, no downstream work is triggered.

**Before (lines 147–155):**
```swift
    private func handleBlockHeight(_ blockHeight: Int64) {
        // Persist only when the value changes (Android lines 104-108).
        if lastBlockHeight != blockHeight {
            lastBlockHeight = blockHeight
            try? storage.save(lastBlockHeight: blockHeight)
        }
        // Always notify the delegate — this heartbeat drives downstream syncs.
        delegate?.didUpdateLastBlockHeight(blockHeight)
    }
```

**After:**
```swift
    private func handleBlockHeight(_ blockHeight: Int64) {
        // A successful RPC response means the poller is healthy — recover from any
        // prior transient error. The didSet guard suppresses duplicate .ready → .ready
        // notifications, so this is a no-op when already in the ready state.
        state = .ready

        // Persist only when the value changes (Android lines 104-108).
        if lastBlockHeight != blockHeight {
            lastBlockHeight = blockHeight
            try? storage.save(lastBlockHeight: blockHeight)
        }
        // Always notify the delegate — this heartbeat drives downstream syncs.
        delegate?.didUpdateLastBlockHeight(blockHeight)
    }
```

---

## Combined final state

After the fix, `handleBlockHeight` in `ApiSyncer.swift` should read:

```swift
    private func handleBlockHeight(_ blockHeight: Int64) {
        // A successful RPC response means the poller is healthy — recover from any
        // prior transient error. The didSet guard suppresses duplicate .ready → .ready
        // notifications, so this is a no-op when already in the ready state.
        state = .ready

        // Persist only when the value changes (Android lines 104-108).
        if lastBlockHeight != blockHeight {
            lastBlockHeight = blockHeight
            try? storage.save(lastBlockHeight: blockHeight)
        }
        // Always notify the delegate — this heartbeat drives downstream syncs.
        delegate?.didUpdateLastBlockHeight(blockHeight)
    }
```
