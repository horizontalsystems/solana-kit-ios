## Code Review — Patch Application (Review 2)

**Reviewing:** Staged changes from patch `20-4-3-transaction-serialization-patch-1.md`
**Changed files:**
- `Sources/SolanaKit/Helper/SolanaSerializer.swift` — 3 fixes (account guard, sig count, docstring)
- `Sources/SolanaKit/Helper/CompactU16.swift` — 1 fix (truncation detection)
- `.ai-factory/patches/20-4-3-transaction-serialization-patch-1.md` — new (patch doc)
- `.ai-factory/reviews/20-4-3-transaction-serialization-review-1.md` — new (review doc)

### Critical Issues

1. **Off-by-one in account count guard — `<= 256` still allows UInt8 overflow** (SolanaSerializer.swift:161)

   The guard reads:
   ```swift
   guard accountKeys.count <= 256 else {
   ```

   This permits exactly 256 accounts. However, the header fields are constructed via `UInt8(groupA.count + groupB.count)` (line 169). If all 256 accounts are signers, the sum is 256, and `UInt8(256)` triggers a fatal runtime trap — the exact crash this guard was supposed to prevent.

   Verified: `swift -e 'let n = 256; let _ = UInt8(n)'` → `Fatal error: Not enough bits to represent the passed value`.

   Similarly, `UInt8(groupD.count)` (line 171) traps if all 256 accounts fall into group D.

   **Fix:** Change `<= 256` to `< 256`:
   ```swift
   guard accountKeys.count < 256 else {
   ```

   With max 255 accounts, every group count and sum fits in UInt8 (0–255). Index values also fit (0–254). This matches the Solana wire format constraint: header fields are u8, so max 255 signers; account indices are u8, so max 256 accounts — but since the header is the tighter constraint, 255 is the correct ceiling.

### Suggestions

None — the remaining three fixes (signature count validation, docstring update, CompactU16 truncation detection) are correctly implemented.

### Verification of Applied Fixes

| # | Fix | Status |
|---|-----|--------|
| 1 | Account count guard | **Off-by-one** — `<= 256` should be `< 256` |
| 2 | `signatureCountMismatch` error + guard in `serialize(signatures:message:)` | Correct — new error case at line 73, guard at lines 308–311 |
| 3 | `buildTransaction()` docstring updated to single-compile flow | Correct — lines 510–523 now show `compile()` → `serialize(message:)` → `serialize(signatures:message:)` |
| 4 | `CompactU16.decode` truncation detection | Correct — `lastByte` tracking + continuation-bit check at lines 44–48, returns `(0, 0)` on truncation |
