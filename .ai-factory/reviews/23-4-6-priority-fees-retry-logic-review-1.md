## Code Review Summary

**Files Reviewed:** 3 (SolanaSerializer.swift, ComputeBudgetProgram.swift, Kit.swift)
**Risk Level:** 🟡 Medium

### Context Gates

- **ARCHITECTURE.md:** WARN — `ComputeBudgetProgram` is in `Programs/`, outside the documented folder structure (which lists `Core/`, `Api/`, `Transactions/`, `Database/`, `Models/`). This is consistent with existing `SystemProgram`/`TokenProgram` in the same directory, so it's a documentation gap, not a code issue.
- **RULES.md:** File does not exist — WARN (no project rules to check against).
- **ROADMAP.md:** OK — Milestone 4.6 is marked `[x]` in the roadmap. All three tasks (deserialization, compute budget parsing, fee estimation) are implemented.

### Critical Issues

None.

### Suggestions

#### 1. `calculateFee` drops priority fee when only one of the two CU instructions is present

**File:** `Sources/SolanaKit/Programs/ComputeBudgetProgram.swift`, lines 120–124

The `guard let` requires **both** `computeUnitPrice` and `computeUnitLimit` to be present. If only one is found, the function returns just the base fee — silently dropping any priority fee component.

The Solana runtime applies these defaults when the instructions are absent:
- Default compute unit price: **0** microLamports (no priority fee)
- Default compute unit limit: **200,000** CU per instruction

The Android reference (`sol4k` `VersionedTransaction`) initializes `cuPrice = 0` / `cuLimit = 200_000` before scanning instructions, so `calculateFee` always computes `price × limit` — even when only one instruction is present.

**Current code:**
```swift
guard let computeUnitPrice = parseComputeUnitPrice(from: compiledMessage),
      let computeUnitLimit  = parseComputeUnitLimit(from: compiledMessage)
else {
    return baseFee / Decimal(1_000_000_000)
}
```

**Suggested fix:**
```swift
let computeUnitPrice = parseComputeUnitPrice(from: compiledMessage) ?? 0
let computeUnitLimit = parseComputeUnitLimit(from: compiledMessage) ?? 200_000

let priorityFee = Decimal(computeUnitPrice) * Decimal(computeUnitLimit) / Decimal(1_000_000)
let totalLamports = baseFee + priorityFee
return totalLamports / Decimal(1_000_000_000)
```

**Impact:** A transaction with `SetComputeUnitPrice(500_000)` but no explicit `SetComputeUnitLimit` would have its priority fee silently zeroed out instead of being calculated with the 200k default. This can occur with externally-built transactions (e.g. Jupiter swap transactions that only set a price). The fee display would underestimate by up to 100 lamports for typical price values.

### Positive Notes

- **Deserializer is well-implemented.** The `deserialize` method correctly handles both legacy and V0 versioned transactions, properly parses address lookup tables for V0, and uses careful bounds checking throughout. The `read()` and `readCompactU16()` helpers handle `Data` slice indices correctly (creating fresh `Data` copies to reset `startIndex`).

- **Version detection is correct.** The `>= 0x80` threshold cleanly distinguishes legacy messages (`numRequiredSignatures` is always 1–127) from versioned message prefixes. The cursor is only advanced for versioned messages, preserving the header byte for legacy parsing.

- **Compute budget parsing is robust.** Both `parseComputeUnitLimit` and `parseComputeUnitPrice` correctly bounds-check `programIdIndex` before array access, validate data length before reading, and use `withUnsafeBytes { $0.load(as:).littleEndian }` which is safe on all platforms (unaligned loads via `UnsafeRawBufferPointer.load(as:)` are supported since Swift 5.7, and the package targets Swift 5.9+).

- **`Kit.estimateFee` is correctly static.** Mirrors the Android pattern where fee estimation doesn't require a kit instance, enabling use from swap adapters before the kit is instantiated.

- **Clean base64 overload.** The `estimateFee(base64EncodedTransaction:)` convenience validates input and throws a clear error, rather than silently producing garbage.
