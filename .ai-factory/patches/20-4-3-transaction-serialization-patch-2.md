# Patch: 20-4-3 Transaction Serialization (Patch 2)

**Review:** `reviews/20-4-3-transaction-serialization-review-2.md`
**Risk:** Low — single-line boundary fix.

---

## Fix 1: Off-by-one in account count guard allows UInt8 overflow

**File:** `Sources/SolanaKit/Helper/SolanaSerializer.swift`
**Line:** 161

**Problem:** The guard `accountKeys.count <= 256` permits exactly 256 accounts. The message header fields are constructed with `UInt8(groupA.count + groupB.count)` (line 169) and `UInt8(groupD.count)` (line 171). If any group count or sum reaches 256, `UInt8(256)` triggers a fatal runtime trap. This is the same crash the guard was introduced to prevent.

Example: 256 accounts all in group D → `UInt8(groupD.count)` = `UInt8(256)` → trap.

The Solana wire format uses u8 for both account indices (max representable index: 255 → max 256 accounts) and header counts (max representable count: 255). The header is the tighter constraint, so the ceiling must be 255 accounts.

**Replace** (lines 160–164):
```swift
        // Solana wire format uses UInt8 indices — more than 256 accounts is invalid.
        guard accountKeys.count <= 256 else {
            throw SerializerError.invalidTransactionData(
                "Transaction references \(accountKeys.count) unique accounts, maximum is 256"
            )
```

**With:**
```swift
        // Solana wire format uses UInt8 for header counts (max 255) and account
        // indices (max 255). Cap at 255 to prevent UInt8 overflow in the header.
        guard accountKeys.count < 256 else {
            throw SerializerError.invalidTransactionData(
                "Transaction references \(accountKeys.count) unique accounts, maximum is 255"
            )
```
