# Review: 4.6 Priority Fees & Retry Logic

**Build:** PASS (xcodebuild, iOS Simulator)
**Files changed:** 3 source files + 1 plan

## File-by-file analysis

### SolanaSerializer.swift — `deserialize(transactionData:)`

**Correctness:** Solid. The deserializer correctly reverses the exact wire format documented in `serialize(message:)`. Key details verified:

- `CompactU16.decode()` accepts `Data` (which is its own `SubSequence` in Swift), so `transactionData[cursor...]` works correctly even when `transactionData` has a non-zero `startIndex`.
- The `read()` helper creates a new `Data(...)` from each slice, resetting indices to 0. All subsequent index arithmetic (e.g., `headerData[headerData.startIndex + 1]`) is safe.
- Version detection (`>= 0x80`) is correct: legacy `numRequiredSignatures` is always 1–127, v0 prefix is `0x80`.
- Silently skipping v0 address lookup tables at the end is safe for fee estimation because ComputeBudget instructions have no account keys and the Compute Budget Program ID is always a static account key.

**No issues found.**

### ComputeBudgetProgram.swift — parsing + `calculateFee`

**Correctness:** The parsing methods are correct:
- Bounds-check on `programIdIndex` before array access.
- Discriminator byte check (`0x02` / `0x03`) and data length validation before reading.
- `withUnsafeBytes { $0.load(as:) }` on `Data` slices is safe — `UnsafeRawBufferPointer.load(as:)` does not require alignment (Swift 5.7+, package targets Swift 5.9+).
- `.littleEndian` on the loaded value is a no-op on all Apple platforms (all LE) and is mathematically equivalent to `init(littleEndian:)` since byte-swap is self-inverse.

**Non-critical issue — `calculateFee` missing defaults:**

`ComputeBudgetProgram.swift:120-124` — the guard requires BOTH `computeUnitPrice` AND `computeUnitLimit` to be present, otherwise falls back to base fee only:

```swift
guard let computeUnitPrice = parseComputeUnitPrice(from: compiledMessage),
      let computeUnitLimit  = parseComputeUnitLimit(from: compiledMessage)
else {
    return baseFee / Decimal(1_000_000_000)
}
```

The Solana runtime uses defaults when these instructions are absent:
- Default CU price: 0 microLamports (no priority fee)
- Default CU limit: 200,000 per instruction

The Android reference (`sol4k` `VersionedTransaction`) initializes with `cuPrice = 0` / `cuLimit = 200_000` before scanning instructions, so `calculateFee` always computes `price * limit` — even when only one instruction is present.

The iOS code produces the wrong fee when a transaction has `SetComputeUnitPrice` but no explicit `SetComputeUnitLimit`: the priority fee is silently dropped instead of being computed with the 200k default. Fix:

```swift
let computeUnitPrice = parseComputeUnitPrice(from: compiledMessage) ?? 0
let computeUnitLimit = parseComputeUnitLimit(from: compiledMessage) ?? 200_000
let priorityFee = Decimal(computeUnitPrice) * Decimal(computeUnitLimit) / Decimal(1_000_000)
let totalLamports = baseFee + priorityFee
return totalLamports / Decimal(1_000_000_000)
```

**Impact:** Low — virtually all modern transaction builders (Jupiter, kit's own `sendSol`/`sendSpl`) set both instructions. The edge case only surfaces with transactions that set `SetComputeUnitPrice` alone.

### Kit.swift — `estimateFee`

**Correctness:** Both overloads are clean pass-throughs. The `base64EncodedTransaction` overload validates input before delegating. Static method correctly avoids requiring a `Kit` instance.

**No issues found.**

## Summary

| # | Severity | Location | Issue |
|---|----------|----------|-------|
| 1 | Non-critical | `ComputeBudgetProgram.swift:120-124` | `calculateFee` requires both CU instructions; should default to 0 price / 200k limit per Android |

No critical or high-severity issues. The implementation is clean, compiles, and handles the common case correctly.

REVIEW_PASS
