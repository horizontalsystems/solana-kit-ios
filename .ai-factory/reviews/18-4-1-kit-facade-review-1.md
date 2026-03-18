# Review: 4.1 Kit Facade

**File reviewed:** `Sources/SolanaKit/Core/Kit.swift`
**Diff scope:** `git diff HEAD` — 4 additions (constants, metadata properties, statusInfo, clear) to the existing Kit facade.
**Build status:** `xcodebuild` BUILD SUCCEEDED (iOS Simulator, iPhone 17)

---

## Summary

The changes add 4 things to the already-complete Kit facade:
1. Three static constants (`baseFeeLamports`, `fee`, `accountRentAmount`)
2. Two public metadata properties (`address: String`, `isMainnet: Bool`)
3. `statusInfo() -> [(String, Any)]` debugging method
4. `Kit.clear(walletId:)` static cleanup method

## Findings

### No issues found

**Constants (lines 16-22):** Values match Android's `SolanaKit.Companion` exactly (`baseFeeLamports = 5000`, `fee = 0.000155`, `accountRentAmount = 0.001`). `Decimal(string:)!` force-unwrap is safe for compile-time string literals — these will never be nil.

**Public metadata (lines 27-30):** `address` and `isMainnet` are `let` properties set once in `init`, correctly threaded from `Kit.instance()` where `address` is the factory parameter and `isMainnet` is derived from `rpcSource.isMainnet`. Matches EvmKit's `public let address: Address` / `public let chain: Chain` pattern.

**Init signature (lines 186-223):** New parameters (`address`, `isMainnet`, `rpcApiProvider`) added consistently to both the `private init` and the `Kit(...)` call site in `Kit.instance()`. All assignments are 1:1 with no parameter reordering issues.

**rpcApiProvider stored property (line 44):** Typed as `IRpcApiProvider` (protocol), not the concrete `RpcApiProvider`. Correct — follows the architecture rule that Kit may hold concrete types internally but the protocol type here is fine since `source` is defined on the protocol. No retain cycle risk — `RpcApiProvider` doesn't reference Kit.

**statusInfo() (lines 155-165):** Returns `[(String, Any)]` matching EvmKit's pattern. `blockHeight > 0 ? blockHeight : "N/A"` handles the default-zero `CurrentValueSubject` case correctly. Accesses `.value` on subjects synchronously — safe, `CurrentValueSubject.value` is thread-safe for reads. `rpcApiProvider.source` returns the host from the URL (verified in `RpcApiProvider.swift:47-49`). No runtime crash paths.

**Kit.clear(walletId:) (lines 353-356):** Delegates to `MainStorage.clear(walletId:)` and `TransactionStorage.clear(walletId:)` — both verified to exist and correctly delete `.sqlite`, `.sqlite-wal`, and `.sqlite-shm` files with `fileExists` guard. If the first clear throws, the second database won't be cleaned — this matches EvmKit's pattern and is acceptable (filesystem errors here are exceptional). No risk of deleting the wrong wallet's files since `walletId` is embedded in the filename.

**No missing migrations:** No database schema changes — this is pure API-surface work on Kit.swift.

**No thread safety issues:** `statusInfo()` reads `.value` from `CurrentValueSubject` (thread-safe) and `rpcApiProvider.source` (computed from immutable `url`). No race conditions.

**No retain cycles:** `rpcApiProvider` is a strong reference to a service object that doesn't reference Kit. The existing `[weak self]` pattern in delegate callbacks is unchanged.

---

REVIEW_PASS
