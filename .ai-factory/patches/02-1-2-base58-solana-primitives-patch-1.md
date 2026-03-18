# Patch: 02-1-2 Base58 & Solana Primitives

**Review:** `02-1-2-base58-solana-primitives-review-1.md`
**Files modified:** 1 (`Sources/SolanaKit/Helper/CompactU16.swift`)

---

## Fix 1: Add precondition to `CompactU16.encode` for input range validation

**Review item:** S2
**File:** `Sources/SolanaKit/Helper/CompactU16.swift`
**Problem:** `encode` accepts any `Int`, but negative values cause an infinite loop (arithmetic right-shift never reaches 0) and values > 65535 produce > 3 bytes, silently creating malformed Solana transactions.
**Fix:** Add a `precondition` at the top of `encode` to enforce the documented 0–65535 range.

### Before (lines 9–12)

```swift
    /// Encodes `value` (0–65535) as compact-u16 bytes.
    static func encode(_ value: Int) -> Data {
        var remaining = value
        var result = Data()
```

### After

```swift
    /// Encodes `value` (0–65535) as compact-u16 bytes.
    static func encode(_ value: Int) -> Data {
        precondition(value >= 0 && value <= 65535, "CompactU16.encode: value \(value) out of range 0–65535")
        var remaining = value
        var result = Data()
```

---

## Fix 2: Add precondition to `CompactU16.decode` for empty data

**Review item:** S1
**File:** `Sources/SolanaKit/Helper/CompactU16.swift`
**Problem:** When called with empty `Data`, the `for` loop never executes and the function returns `(value: 0, bytesRead: 0)`. Any caller advancing a buffer cursor by `bytesRead` will infinite-loop. The downstream `SolanaSerializer` already guards against this, but the primitive itself should fail fast.
**Fix:** Add a `precondition` at the top of `decode` to reject empty input.

### Before (lines 27–30)

```swift
    static func decode(_ data: Data) -> (value: Int, bytesRead: Int) {
        var value = 0
        var bytesRead = 0
        var shift = 0
```

### After

```swift
    static func decode(_ data: Data) -> (value: Int, bytesRead: Int) {
        precondition(!data.isEmpty, "CompactU16.decode: called with empty data")
        var value = 0
        var bytesRead = 0
        var shift = 0
```
