## Code Review — Patch Round 2

**Reviewing:** Patch from `reviews/23-4-6-priority-fees-retry-logic-review-1.md`
**Changed files:** `Sources/SolanaKit/Programs/ComputeBudgetProgram.swift` (code), 2 `.ai-factory/` artifacts

### Change Summary

Single code change in `ComputeBudgetProgram.calculateFee` (lines 118–131): replaced a `guard let` that required both `SetComputeUnitPrice` and `SetComputeUnitLimit` instructions with nil-coalescing defaults (`?? 0` for price, `?? 200_000` for limit). Docstring updated to reflect new behavior.

### Verification

All four input combinations produce correct results:

| CU Price instruction | CU Limit instruction | Result |
|---|---|---|
| Present | Present | Uses both parsed values (unchanged) |
| Absent | Absent | `0 × 200_000 / 1M = 0` priority → base fee only (same net result as before) |
| Present | Absent | Parsed price × 200,000 default limit (**fixed** — was returning base fee only) |
| Absent | Present | `0 × parsed limit = 0` priority → base fee only (correct, default price is 0) |

### Issues Found

None. The fix is minimal, correct, and matches the Android `sol4k` reference behavior.

REVIEW_PASS
