# Review: 5.3 TokenProvider — Round 2

## Files Reviewed

| File | Status |
|------|--------|
| `Sources/SolanaKit/Models/TokenInfo.swift` | Modified |
| `Sources/SolanaKit/Core/TokenProvider.swift` | New |
| `Sources/SolanaKit/Core/Kit.swift` | Modified |
| `Sources/SolanaKit/Api/JupiterApiService.swift` | Modified |

## Round 1 Fix Verification

The critical issue from round 1 — `JupiterError` trapped inside an internal class — is fixed. `JupiterError` is now a top-level `public enum` at module scope (JupiterApiService.swift:176). All six internal `throw JupiterError.xxx` call sites use the bare name and resolve correctly. External consumers can now `catch JupiterError.tokenNotFound`.

## Critical Issues

None.

## Non-Critical Observations

Carried forward from round 1 — no action required:

- **`TokenInfo` has no public memberwise init.** The auto-generated init is `internal`. External code cannot construct a `TokenInfo`, only consume it. Fine for production use; could be inconvenient for wallet-side unit tests wanting to create mock instances. Add a `public init` later if needed.

- **`Kit.tokenInfo(...)` and `TokenProvider` are redundant by design.** Both create a temporary `JupiterApiService` and delegate. Matches the dual-path pattern (static method + instantiable type) seen in the EVM kit ecosystem.

## Correctness Checklist

- [x] `TokenInfo` is `public struct` with `public let` properties — wallet can read all fields
- [x] `TokenProvider` is `public final class` with `public init` — wallet can instantiate it
- [x] `TokenProvider.tokenInfo(mintAddress:)` delegates to `IJupiterApiService` protocol — testable via mock
- [x] `Kit.tokenInfo(networkManager:apiKey:mintAddress:)` is `static` — no `Kit` instance required
- [x] `JupiterError` is top-level `public enum` — wallet can catch `.tokenNotFound`, `.invalidResponse`
- [x] All existing `throw JupiterError.xxx` sites unaffected (bare name resolves to top-level enum)
- [x] No database migrations needed (no schema changes)
- [x] No new SPM dependencies
- [x] Architecture rules respected: only `Kit`, `Signer`, `TokenProvider`, `TokenInfo`, and `JupiterError` are `public`; `JupiterApiService` stays `internal`

REVIEW_PASS
