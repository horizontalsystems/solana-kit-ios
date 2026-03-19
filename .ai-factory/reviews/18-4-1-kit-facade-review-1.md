## Code Review Summary

**Files Reviewed:** 1 (`Sources/SolanaKit/Core/Kit.swift`)
**Risk Level:** 🟢 Low

### Context Gates

- **ARCHITECTURE.md** — WARN: No violations. Constants, metadata, `statusInfo()`, and `clear()` are all on the public `Kit` facade. `rpcApiProvider` is stored as a protocol reference (`IRpcApiProvider`), not a concrete type. All `.send()` calls on subjects remain dispatched to `DispatchQueue.main`. Layer rules respected.
- **RULES.md** — File does not exist. WARN (non-blocking).
- **ROADMAP.md** — Milestone 4.1 is listed and marked `[x]`. Changes align with the described scope ("Kit.swift: static Kit.instance(...) factory with full DI, Combine publishers, start()/stop() lifecycle, statusInfo() for debugging"). No linkage issues.

### Critical Issues

None.

### Suggestions

None.

### Positive Notes

- **Constants match Android exactly.** `baseFeeLamports = 5000`, `fee = 0.000155`, `accountRentAmount = 0.001` all correspond to the Android `companion object` values. Using `Decimal(string:)!` for the fee constants avoids the floating-point imprecision that Android's `BigDecimal(double)` constructor introduces — actually an improvement.
- **`statusInfo()` is richer than Android.** The iOS version includes Token Sync State, Transactions Sync State, and RPC Source — Android only returns Last Block Height and Sync State. The extra fields are useful for debugging without adding any cost.
- **`clear(walletId:)` correctly delegates to both storage `clear` methods.** Both `MainStorage.clear` and `TransactionStorage.clear` handle all three SQLite files (`.sqlite`, `.sqlite-wal`, `.sqlite-shm`) with existence checks before deletion. Pattern matches EvmKit's file-based cleanup.
- **`rpcApiProvider` stored as protocol, not concrete type.** Consistent with the architecture rule that Core depends on protocol interfaces, not infrastructure types.
- **`isMainnet` derivation is clean.** Computed once from `rpcSource.isMainnet` at construction time and stored as a `let` — no repeated computation, no risk of the RPC source changing underneath.
- **All new `init` parameters are threaded through consistently.** The `address`, `isMainnet`, and `rpcApiProvider` are added to `private init`, assigned in the body, and passed from `Kit.instance()` — no missed wiring.

REVIEW_PASS
