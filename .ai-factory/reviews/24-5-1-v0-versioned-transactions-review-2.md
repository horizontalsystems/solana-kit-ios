# Review 2: 5.1 V0 Versioned Transactions

**Plan:** `.ai-factory/plans/24-5-1-v0-versioned-transactions.md`
**Files changed:** `SolanaSerializer.swift`, `TransactionManager.swift`, `Kit.swift`
**Reviewer scope:** Bugs, correctness, runtime failures, security, type mismatches
**Prior review:** review-1 found one critical compile error (`let (var ...)`) — verified fixed.

---

## Critical Issues

None found.

---

## Review-1 Fix Verification

The critical compile error from review-1 has been resolved:

**Before (review-1):**
```swift
let (var signatures, message) = try SolanaSerializer.deserialize(transactionData: rawTransaction)
```

**After (current):** `TransactionManager.swift:433`
```swift
var (signatures, message) = try SolanaSerializer.deserialize(transactionData: rawTransaction)
```

This is valid Swift. `message` becomes unnecessarily mutable but that's harmless and idiomatic for this pattern.

---

## Type Verification

All cross-boundary type signatures verified against source definitions:

| Call site | Expected signature | Verified |
|---|---|---|
| `Signer.sign(data: messageBytes)` | `(Data) throws -> Data` (64 bytes) | Yes — `Signer.swift:41` |
| `Base58.encode(message.recentBlockhash)` | `(Data) -> String` | Yes — `Base58.swift:19` |
| `PublicKey(data: keyData)` | `(Data) throws` | Yes — `PublicKey.swift:17` |
| `PublicKey.data` property | `Data` (32 bytes) | Yes — `PublicKey.swift:12` |
| `ComputeBudgetProgram.calculateFee(from:baseFeeLamports:)` | `(CompiledMessage, Int64) -> Decimal` | Yes — `ComputeBudgetProgram.swift:117` |
| `rpcApiProvider.sendTransaction(serializedBase64:)` | `(String) async throws -> String` | Yes — `Protocols.swift:251` |
| `rpcApiProvider.getLatestBlockhash()` | `() async throws -> RpcBlockhashResponse` (has `.lastValidBlockHeight: Int64`) | Yes — `Protocols.swift:255` |
| `CompactU16.encode(_:)` | `(Int) -> Data` | Yes — `CompactU16.swift:10` |
| `storage.save(transactions:)` | `([Transaction]) throws` | Yes — `Protocols.swift:36` |
| `Transaction` init — all param types match usage | fee: `String?`, from: `String?`, to: `String?`, etc. | Yes — `Transaction.swift:47-60` |
| `FullTransaction` memberwise init | `(transaction: Transaction, tokenTransfers: [FullTokenTransfer])` | Yes — `FullTransaction.swift:9-14` |

---

## Serialization Correctness

### V0 serialize(message:) — `SolanaSerializer.swift:240-285`

Wire format produced:
```
[0x80]          version prefix (V0 only)
[3 bytes]       header
[compact-u16]   accountKeys.count
[32 * n]        accountKeys
[32]            recentBlockhash
[compact-u16]   instructions.count
[per-ix]        programIdIndex + accountIndices + data
[compact-u16]   addressLookupTables.count (V0 only)
[per-ALT]       32-byte pubkey + writable indexes + readonly indexes (V0 only)
```

This matches the [Solana V0 message spec](https://docs.solana.com/developing/versioned-transactions). Legacy messages omit the prefix and ALT section — unchanged from before.

### V0 deserialize(transactionData:) — `SolanaSerializer.swift:331-479`

- Version detection at `:382` — byte `>= 0x80` → V0, consume byte; else legacy, don't consume.
- ALT parsing at `:440-467` — reads compact-u16 table count, then per table: 32-byte pubkey + writable/readonly index arrays.
- Both paths construct `CompiledMessage` with the detected `version` and parsed `addressLookupTables`.

### Round-trip integrity

Trace: `deserialize(V0 wire bytes)` → `CompiledMessage(version: .v0, addressLookupTables: [...])` → `serialize(message:)` → reproduces original message bytes including `0x80` prefix and ALT section → `serialize(signatures:message:)` → reproduces original full wire bytes (with updated signatures).

The signed payload for both V0 and legacy transactions is `serialize(message:)` output, which correctly includes the `0x80` version prefix for V0. This is what Solana validators expect.

### Legacy backward compatibility

`compile()` at `:194-201` always returns `.legacy` with empty `addressLookupTables`. All existing callers (`serializeMessage`, `buildTransaction`, `sendSol`, `sendSpl`) go through `compile()`, so they produce identical wire output to before.

---

## sendRawTransaction Flow — `TransactionManager.swift:431-488`

| Step | Code | Correct |
|------|------|---------|
| 1. Deserialize | `SolanaSerializer.deserialize(transactionData:)` | Yes |
| 2. Re-serialize message (signable bytes) | `SolanaSerializer.serialize(message:)` — includes 0x80 for V0 | Yes |
| 3. Sign | `signer.sign(data: messageBytes)` → 64-byte `Data` | Yes |
| 4. Replace fee-payer sig (slot 0) | `signatures[0] = signature` (or `[signature]` if empty) | Yes |
| 5. Re-serialize full tx | `SolanaSerializer.serialize(signatures:message:)` | Yes |
| 6. Broadcast | `rpcApiProvider.sendTransaction(serializedBase64:)` | Yes |
| 7. Fetch blockhash for expiry tracking | `rpcApiProvider.getLatestBlockhash()` | Yes (see note 1 below) |
| 8. Estimate fee | `ComputeBudgetProgram.calculateFee(from:baseFeeLamports:)` | Yes |
| 9. Persist pending tx | `storage.save(transactions:)` with `base64Encoded` for retry | Yes |
| 10. Emit via Combine | `transactionsSubject.send([fullTx])` on main queue | Yes |

**Kit.swift:236-238** — `sendRawTransaction` delegates to `transactionManager.sendRawTransaction`, matching the identical pattern used by `sendSol` (`:197-198`) and `sendSpl` (`:216-217`).

---

## Non-Critical Observations

### 1. `lastValidBlockHeight` from fresh blockhash (matches Android)

`TransactionManager.swift:457` — The `lastValidBlockHeight` stored comes from a fresh `getLatestBlockhash()` call, not the blockhash embedded in the raw transaction. This means `PendingTransactionSyncer` may use a slightly newer expiry window than the actual transaction's blockhash.

**Severity:** Low. Faithfully mirrors Android `SolanaKit.kt:223`. Worst case: a few extra futile retries before the syncer gives up. No state corruption.

### 2. Version detection treats `>= 0x80` as V0

`SolanaSerializer.swift:382` — Any byte `>= 0x80` is treated as V0 rather than checking for exactly `0x80`. A hypothetical V1 (`0x81`) would be misinterpreted.

**Severity:** Very low. Only V0 exists today. Pre-existing behavior, not introduced by this PR. When V1 appears, the entire versioned parsing logic needs updating anyway.

### 3. No validation that signer matches fee payer

`TransactionManager.swift:440` — No guard that `signer.publicKey == message.accountKeys[0]`. A mismatch causes an on-chain signature verification failure (opaque error).

**Severity:** Low. Matches Android behavior. The transaction simply fails on-chain and gets marked failed by the pending syncer. A guard would improve DX but is not required.

### 4. Lenient ALT parsing for truncated V0 messages

`SolanaSerializer.swift:441` — The `cursor < transactionData.endIndex` guard means a V0 message with no trailing ALT bytes is silently treated as having zero lookup tables rather than throwing.

**Severity:** Very low. A conformant V0 message always has the ALT count byte (even if it's 0). This leniency is defensible for a wallet client that may encounter truncated data.

---

## Verification Checklist

| Check | Result |
|-------|--------|
| Review-1 critical fix applied (`var (signatures, message)`) | Verified at `:433` |
| V0 serialization: `0x80` prefix prepended | Correct (`:244`) |
| V0 serialization: ALT section appended after instructions | Correct (`:273-282`) |
| V0 deserialization: version byte consumed and recorded | Correct (`:381-387`) |
| V0 deserialization: ALT section parsed with correct layout | Correct (`:440-467`) |
| Legacy messages: unchanged wire format | Correct — `compile()` returns `.legacy` with empty ALTs |
| Round-trip: deserialize → re-serialize preserves wire bytes | Correct |
| `sendRawTransaction`: all type signatures match | Verified against source definitions |
| `sendRawTransaction`: persist with `base64Encoded` for PendingTransactionSyncer retry | Correct |
| `Kit.sendRawTransaction`: delegation pattern consistent with `sendSol`/`sendSpl` | Correct |
| Fee estimation: `calculateFee` works with V0 messages (reads header/instructions only) | Correct |
| Thread safety: same `DispatchQueue.main.async` + `[weak self]` pattern as existing sends | Correct |
| No missing database migrations | Confirmed — no schema changes, only new in-memory types |
| No new public types leaking internal details | Confirmed — new types are internal to `SolanaSerializer` |

---

## Summary

All critical issues from review-1 have been resolved. The V0 serialization/deserialization is correct and produces wire-compatible output matching the Solana spec. The `sendRawTransaction` flow correctly handles the deserialize → re-sign → re-serialize → broadcast pipeline for both legacy and V0 transactions. All type signatures verified against source definitions. Four non-critical observations noted for awareness — all match Android behavior or are pre-existing patterns.

REVIEW_PASS
