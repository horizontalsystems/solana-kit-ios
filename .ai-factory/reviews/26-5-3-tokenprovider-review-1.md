# Review: 5.3 TokenProvider — Round 1

## Files Reviewed

| File | Status |
|------|--------|
| `Sources/SolanaKit/Models/TokenInfo.swift` | Modified |
| `Sources/SolanaKit/Core/TokenProvider.swift` | New |
| `Sources/SolanaKit/Core/Kit.swift` | Modified |
| `Sources/SolanaKit/Api/JupiterApiService.swift` | Modified |

## Critical Issues

### 1. `JupiterError` is inaccessible outside the module despite `public` keyword

**File:** `Sources/SolanaKit/Api/JupiterApiService.swift:173`

`JupiterError` is declared `public enum JupiterError` but it is nested inside `JupiterApiService`, which is `internal` (implicit — no access modifier). In Swift, the effective access level of a nested type is `min(enclosing type, declared)` = `min(internal, public)` = **`internal`**.

External consumers (the wallet layer) **cannot reference** `JupiterApiService.JupiterError` because `JupiterApiService` itself is not visible outside the module. The `public` keyword on the enum is misleading — it compiles but has no effect.

This defeats the purpose of Task 4. The wallet's `AddSolanaTokenBlockchainService` will want to catch `.tokenNotFound` to display a user-facing error, but it cannot write:
```swift
catch JupiterApiService.JupiterError.tokenNotFound {
    // unreachable — JupiterApiService is invisible
}
```

**Fix:** Move `JupiterError` out of `JupiterApiService` to the module top level (or into `TokenProvider`/`Kit`) so external callers can reference it. For example:
```swift
// Option A: Top-level public enum in JupiterApiService.swift
public enum JupiterError: Error {
    case invalidResponse
    case tokenNotFound(mintAddress: String)
    case quoteNotAvailable
    case swapFailed(String)
}
```
Then update `JupiterApiService` to reference `JupiterError` without the nesting prefix. Internal call sites (`JupiterApiService.tokenInfo()`) already throw bare `JupiterError.tokenNotFound(...)` so they need no change.

Alternatively, add a `public typealias JupiterError = JupiterApiService.JupiterError` on `Kit` or `TokenProvider` — but typealiases cannot re-export a type whose enclosing scope is invisible, so this won't work either. Moving the enum to the top level is the clean fix.

## Non-Critical Observations

### `TokenInfo` has no public memberwise initializer

`TokenInfo` is now `public struct` with `public let` properties, but it has no explicit `public init(name:symbol:decimals:)`. Swift auto-generates a memberwise init at `internal` access level. External consumers can read all properties but cannot construct a `TokenInfo`. This is fine for the actual use case (wallet receives `TokenInfo` from `TokenProvider`/`Kit` — never constructs one) but could be inconvenient for wallet-side unit tests that want to create mock instances. Low priority — no action required unless the wallet integration demands it.

### `Kit.tokenInfo(...)` and `TokenProvider` are redundant

Both `Kit.tokenInfo(networkManager:apiKey:mintAddress:)` and `TokenProvider(networkManager:apiKey:).tokenInfo(mintAddress:)` do the exact same thing — create a `JupiterApiService` and call `.tokenInfo()`. This is by design (plan Tasks 2 and 3) and matches how EVM Kit offers both a static method and an instantiable type. No action needed, but worth noting that one would suffice.

## Summary

One critical issue: `JupiterError` is trapped inside an internal type and unreachable by the wallet. The remaining changes (public `TokenInfo`, `TokenProvider` class, `Kit.tokenInfo(...)` static method) are correct, clean, and match the Android reference.

REVIEW_FAIL — fix the `JupiterError` access level issue before shipping.
