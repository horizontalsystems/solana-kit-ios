# Patch: 23-4-6 Priority Fees & Retry Logic

**Review:** `reviews/23-4-6-priority-fees-retry-logic-review-1.md`
**Issue count:** 1

---

## Fix 1: Use Solana runtime defaults in `calculateFee` when CU instructions are missing

**File:** `Sources/SolanaKit/Programs/ComputeBudgetProgram.swift`
**Lines:** 117–130
**Severity:** Medium — causes incorrect fee estimation for externally-built transactions

### Problem

`calculateFee` uses a `guard let` that requires **both** `SetComputeUnitPrice` and `SetComputeUnitLimit` instructions to be present. When only one is found (e.g. a Jupiter swap transaction that sets a price but omits the limit), the function falls through to the `else` branch and returns just the base fee — silently dropping the priority fee.

The Solana runtime applies defaults when these instructions are absent:
- Compute unit price default: **0** microLamports
- Compute unit limit default: **200,000** CU

The Android reference (`sol4k`) initializes `cuPrice = 0` / `cuLimit = 200_000` before scanning, so the fee formula always runs.

### Current code

```swift
static func calculateFee(from compiledMessage: SolanaSerializer.CompiledMessage, baseFeeLamports: Int64) -> Decimal {
    let baseFee = Decimal(baseFeeLamports)

    guard let computeUnitPrice = parseComputeUnitPrice(from: compiledMessage),
          let computeUnitLimit  = parseComputeUnitLimit(from: compiledMessage)
    else {
        return baseFee / Decimal(1_000_000_000)
    }

    // Priority fee: microLamports × CU ÷ 1_000_000 = lamports
    let priorityFee = Decimal(computeUnitPrice) * Decimal(computeUnitLimit) / Decimal(1_000_000)
    let totalLamports = baseFee + priorityFee
    return totalLamports / Decimal(1_000_000_000)
}
```

### Fixed code

```swift
static func calculateFee(from compiledMessage: SolanaSerializer.CompiledMessage, baseFeeLamports: Int64) -> Decimal {
    let baseFee = Decimal(baseFeeLamports)

    // Solana runtime defaults: 0 microLamports price, 200_000 CU limit.
    // Matches sol4k VersionedTransaction which initializes cuPrice=0, cuLimit=200_000
    // before scanning instructions.
    let computeUnitPrice = parseComputeUnitPrice(from: compiledMessage) ?? 0
    let computeUnitLimit = parseComputeUnitLimit(from: compiledMessage) ?? 200_000

    // Priority fee: microLamports × CU ÷ 1_000_000 = lamports
    let priorityFee = Decimal(computeUnitPrice) * Decimal(computeUnitLimit) / Decimal(1_000_000)
    let totalLamports = baseFee + priorityFee
    return totalLamports / Decimal(1_000_000_000)
}
```

### Exact edit

Replace lines 117–130:

**old_string:**
```
    static func calculateFee(from compiledMessage: SolanaSerializer.CompiledMessage, baseFeeLamports: Int64) -> Decimal {
        let baseFee = Decimal(baseFeeLamports)

        guard let computeUnitPrice = parseComputeUnitPrice(from: compiledMessage),
              let computeUnitLimit  = parseComputeUnitLimit(from: compiledMessage)
        else {
            return baseFee / Decimal(1_000_000_000)
        }

        // Priority fee: microLamports × CU ÷ 1_000_000 = lamports
        let priorityFee = Decimal(computeUnitPrice) * Decimal(computeUnitLimit) / Decimal(1_000_000)
        let totalLamports = baseFee + priorityFee
        return totalLamports / Decimal(1_000_000_000)
    }
```

**new_string:**
```
    static func calculateFee(from compiledMessage: SolanaSerializer.CompiledMessage, baseFeeLamports: Int64) -> Decimal {
        let baseFee = Decimal(baseFeeLamports)

        // Solana runtime defaults: 0 microLamports price, 200_000 CU limit.
        // Matches sol4k VersionedTransaction which initializes cuPrice=0, cuLimit=200_000
        // before scanning instructions.
        let computeUnitPrice = parseComputeUnitPrice(from: compiledMessage) ?? 0
        let computeUnitLimit = parseComputeUnitLimit(from: compiledMessage) ?? 200_000

        // Priority fee: microLamports × CU ÷ 1_000_000 = lamports
        let priorityFee = Decimal(computeUnitPrice) * Decimal(computeUnitLimit) / Decimal(1_000_000)
        let totalLamports = baseFee + priorityFee
        return totalLamports / Decimal(1_000_000_000)
    }
```

### Docstring update

Also update the doc comment above `calculateFee` (lines 113–114) to reflect the new default behavior:

**old_string:**
```
    /// If no compute budget instructions are found, only the base fee (converted to SOL) is returned.
```

**new_string:**
```
    /// Uses Solana runtime defaults (0 microLamports price, 200,000 CU limit) when
    /// the corresponding instruction is absent.
```

### Verification

After applying this fix, the behavior for all cases is correct:
- **Both instructions present:** uses parsed values (unchanged)
- **Neither instruction present:** `0 × 200_000 / 1M = 0` priority fee → returns base fee only (same result as before, just computed via the formula instead of early return)
- **Only price present:** uses parsed price × 200,000 default limit (previously returned base fee only — **fixed**)
- **Only limit present:** uses 0 default price × parsed limit = 0 priority fee → returns base fee only (correct, since default price is 0)
