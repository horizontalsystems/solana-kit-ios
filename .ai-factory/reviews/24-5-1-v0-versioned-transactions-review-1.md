# Review: 5.1 V0 Versioned Transactions

**Plan:** `.ai-factory/plans/24-5-1-v0-versioned-transactions.md`
**Files changed:** `SolanaSerializer.swift`, `TransactionManager.swift`, `Kit.swift`
**Reviewer scope:** Bugs, correctness, runtime failures, security

---

## Critical Issues

### 1. COMPILE ERROR: `let (var signatures, message)` — invalid Swift syntax

**File:** `TransactionManager.swift:433`
```swift
let (var signatures, message) = try SolanaSerializer.deserialize(transactionData: rawTransaction)
```

Swift does not allow `var` nested inside another `let` or `var` pattern binding. The compiler emits:
```
error: 'var' cannot appear nested inside another 'var' or 'let' pattern
```

**Fix:** Change to `var (signatures, message)`:
```swift
var (signatures, message) = try SolanaSerializer.deserialize(transactionData: rawTransaction)
```

This makes both bindings `var`. `message` doesn't need mutation, but the extra mutability is harmless and this is the idiomatic Swift pattern for this case.

> **Note:** This error is currently masked because `swift build` fails at the dependency-resolution level (platform version mismatches in HsToolKit/HdWalletKit), so source compilation never runs. It will surface the moment dependency issues are resolved or when building via Xcode for an iOS target.

---

## Non-Critical Issues

### 2. `lastValidBlockHeight` from mismatched blockhash (matches Android — informational)

**File:** `TransactionManager.swift:457`
```swift
let blockhashResponse = try await rpcApiProvider.getLatestBlockhash()
```

The raw transaction was built with a specific `recentBlockhash` by the external caller. The `lastValidBlockHeight` stored in the pending `Transaction` record comes from a **fresh** `getLatestBlockhash()` call, which likely returns a different (newer) blockhash. This means `PendingTransactionSyncer` may continue retrying a transaction whose original blockhash has already expired, since the stored `lastValidBlockHeight` corresponds to a newer slot.

**Severity:** Low. This faithfully mirrors the Android implementation (`SolanaKit.kt:223`). The worst case is a few extra futile retry attempts before the syncer gives up. No data corruption or incorrect state.

### 3. Version detection treats all `>= 0x80` as V0

**File:** `SolanaSerializer.swift:382`
```swift
if transactionData[cursor] >= 0x80 {
    messageVersion = .v0
```

Solana encodes versioned messages as `0x80 | version_number`. V0 = `0x80`, a hypothetical V1 = `0x81`, etc. The code treats any byte `>= 0x80` as V0 rather than checking for exactly `0x80`.

**Severity:** Very low. Only V0 exists on Solana today and no other versions are planned. When/if V1 appears, this will need updating — but so will the entire V0 serialization/deserialization logic. This matches the pre-existing behavior from the original deserializer.

### 4. No validation that signer matches the fee payer in the message

**File:** `TransactionManager.swift:440`

The code signs the message and replaces signature slot 0 (the fee payer's slot) without verifying that `signer.publicKey` matches `message.accountKeys[0]`. If the caller passes a mismatched signer, the transaction will broadcast but fail on-chain with an opaque signature verification error.

**Severity:** Low. The Android code also does not validate this (`SolanaKit.kt:218`). The transaction would simply fail on-chain, and the pending transaction syncer would eventually mark it as failed. A guard with a clear error message would improve DX but is not required for correctness.

---

## Verification Checklist

| Check | Result |
|-------|--------|
| V0 serialization: `0x80` prefix prepended | Correct (`SolanaSerializer.swift:244`) |
| V0 serialization: ALT section appended after instructions | Correct (`SolanaSerializer.swift:273-282`) |
| V0 deserialization: version byte consumed and recorded | Correct (`SolanaSerializer.swift:381-387`) |
| V0 deserialization: ALT section parsed with correct layout | Correct (`SolanaSerializer.swift:441-467`) |
| Legacy messages: unchanged behavior, version=`.legacy`, empty ALTs | Correct |
| `compile()`: returns `.legacy` with empty ALTs | Correct (`SolanaSerializer.swift:199-200`) |
| `serialize(signatures:message:)`: delegates to `serialize(message:)` which handles V0 | Correct (`SolanaSerializer.swift:310`) |
| Round-trip: deserialize → re-serialize preserves V0 wire format | Correct (ALTs are parsed and re-emitted) |
| `sendRawTransaction`: sign → replace slot 0 → reserialize → broadcast | Correct (matches Android `addSignature` behavior) |
| `sendRawTransaction`: persist pending tx with `base64Encoded` for retry | Correct (improvement over Android which doesn't persist) |
| `Kit.sendRawTransaction`: delegation pattern matches `sendSol`/`sendSpl` | Correct |
| Fee estimation: uses `ComputeBudgetProgram.calculateFee` | Correct |
| `estimateFee(rawTransaction:)`: existing static method works with V0 | Correct (deserialize now returns V0 messages; `calculateFee` only reads header/instructions) |
| Type signatures: `Signer.sign(data:)` returns `Data` (64 bytes) | Verified |
| Type signatures: `Base58.encode(_:)` accepts `Data` | Verified |
| Type signatures: `Transaction` init defaults match usage | Verified |

---

## Summary

One critical compile error (`let (var ...)`) that must be fixed before merge. The serialization and deserialization logic for V0 is correct and properly handles both legacy and versioned formats. The `sendRawTransaction` flow faithfully mirrors the Android implementation with a reasonable enhancement (persistence for retry). Three non-critical observations noted for awareness.

**Action required:** Fix the tuple binding syntax at `TransactionManager.swift:433`.

REVIEW_FAIL
