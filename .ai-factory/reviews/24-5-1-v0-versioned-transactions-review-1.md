## Code Review Summary

**Files Reviewed:** 3
**Risk Level:** 🟢 Low

### Context Gates

- **ARCHITECTURE.md** — WARN: The architecture doc states "`Kit` never touches key material; it only accepts pre-signed serialized bytes" and the anti-pattern list says "Putting signing logic in `Kit`" is forbidden. However, `sendRawTransaction` passes a `Signer` through `Kit` into `TransactionManager` where signing occurs. This is consistent with `sendSol`/`sendSpl` (which do the same thing) — so the architecture doc's examples are aspirational rather than enforced. No action needed, but the architecture doc is outdated relative to the actual signing pattern used by all send methods.
- **RULES.md** — no file present (WARN: non-blocking).
- **ROADMAP.md** — Milestone 5.1 is marked `[x]` and description matches the implementation. No alignment issues.

### Critical Issues

None found.

### Suggestions

1. **`sendRawTransaction` broadcasts before fetching blockhash — risk of untracked transaction** (`TransactionManager.swift` lines 453-457)

   The iOS code sends the transaction first, then fetches a fresh blockhash for `lastValidBlockHeight`. If the blockhash fetch fails after a successful broadcast, the method throws and the successfully-broadcast transaction is never persisted — meaning `PendingTransactionSyncer` won't track it and the caller sees an error despite the transaction being on-chain.

   The Android reference does it the other way: `getLatestBlockhashExtended` first (line 223), then `sendTransaction` (line 225). Consider reordering to match Android:

   ```swift
   // 6. Fetch fresh blockhash first (matches Android ordering).
   let blockhashResponse = try await rpcApiProvider.getLatestBlockhash()
   // 7. Broadcast.
   let txHash = try await rpcApiProvider.sendTransaction(serializedBase64: base64Tx)
   ```

2. **Mismatched `blockHash` / `lastValidBlockHeight` in `sendRawTransaction`** (`TransactionManager.swift` lines 464-476)

   The persisted `blockHash` comes from the message's embedded `recentBlockhash` (set by the external builder, e.g. Jupiter), while `lastValidBlockHeight` comes from a fresh `getLatestBlockhash()` call. These are from different points in time, so `lastValidBlockHeight` may be higher than the actual validity window of the embedded blockhash.

   This means `PendingTransactionSyncer` could keep re-broadcasting (line 82-84 of `PendingTransactionSyncer.swift`) after the transaction's actual blockhash has expired. Re-broadcast errors are silently swallowed so this won't crash, but it wastes network calls.

   The Android version has the same behavior (fresh `lastValidBlockHeight` paired with the transaction's embedded blockhash), so this is functionally consistent. Flagging for awareness only.

3. **Version byte detection treats all `>= 0x80` as V0** (`SolanaSerializer.swift` line 396)

   The deserializer maps any byte `>= 0x80` to `.v0`. Solana's versioned format encodes the version as `0x80 | version_number`, so a hypothetical V1 (`0x81`) would be incorrectly parsed as V0. This matches current sol4k behavior and no other versions exist today, but adding a guard/warning for unexpected version bytes would be defensive:

   ```swift
   if transactionData[cursor] >= 0x80 {
       let versionByte = transactionData[cursor]
       guard versionByte == 0x80 else {
           throw SerializerError.invalidTransactionData(
               "Unsupported message version: \(versionByte & 0x7F)"
           )
       }
       messageVersion = .v0
       cursor += 1
   }
   ```

### Positive Notes

- V0 serialization/deserialization is correctly round-trip compatible — `serialize(message:)` produces the `0x80` prefix and ALT section that `deserialize()` expects
- The `compile()` method correctly defaults to `.legacy` with empty `addressLookupTables`, ensuring all existing callers (`sendSol`, `sendSpl`, `estimateFee`) are unaffected
- Address lookup table parsing in `deserialize()` is thorough with proper error handling and descriptive error messages
- `reserveCapacity` calls for ALT arrays show attention to allocation performance
- `sendRawTransaction` follows the identical persist-and-emit pattern established by `sendSol`/`sendSpl` — consistent codebase
- All `transactionsSubject.send()` calls correctly dispatch on `DispatchQueue.main`, matching the architecture requirement
- Good documentation with doc comments that reference both the Android reference and the wire format layout

REVIEW_PASS
