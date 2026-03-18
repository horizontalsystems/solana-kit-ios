# Plan: V0 Versioned Transactions

## Context
Extend SolanaSerializer and the send pipeline to support Solana V0 transaction format (address lookup tables), then add a `sendRawTransaction` public API on Kit for broadcasting externally-built transactions (e.g. Jupiter swaps). Android reference: `SolanaKit.sendRawTransaction()` + sol4k `VersionedTransaction`.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: V0 Serialization Support

- [x] **Task 1: Add V0 model types and extend CompiledMessage**
  Files: `Sources/SolanaKit/Helper/SolanaSerializer.swift`
  Add two new nested types inside `SolanaSerializer`:
  - `enum MessageVersion { case legacy, v0 }` — mirrors sol4k `TransactionMessage.MessageVersion`.
  - `struct CompiledAddressLookupTable` with fields `publicKey: PublicKey`, `writableIndexes: [UInt8]`, `readonlyIndexes: [UInt8]` — mirrors sol4k `CompiledAddressLookupTable.kt`.

  Extend `CompiledMessage` with two new fields:
  - `let version: MessageVersion` (default-like: `.legacy` for all compile-generated messages)
  - `let addressLookupTables: [CompiledAddressLookupTable]` (empty array for legacy messages)

  Update `compile(feePayer:instructions:recentBlockhash:)` (line 170) to pass `version: .legacy` and `addressLookupTables: []` when constructing the returned `CompiledMessage`.

- [x] **Task 2: Update serialize(message:) for V0 format** (depends on Task 1)
  Files: `Sources/SolanaKit/Helper/SolanaSerializer.swift`
  Modify `serialize(message:)` (currently line 198) to be version-aware:
  - For `.legacy`: output is unchanged (3-byte header + accounts + blockhash + instructions).
  - For `.v0`: prepend a single byte `0x80` before the header, then after instructions append the address lookup tables section:
    ```
    [compact-u16] addressLookupTables.count
    for each table:
      [32 bytes]    table publicKey
      [compact-u16] writableIndexes.count
      [N bytes]     writableIndexes
      [compact-u16] readonlyIndexes.count
      [N bytes]     readonlyIndexes
    ```
  This matches sol4k `TransactionMessage.serialize()`. Legacy callers (`serializeMessage`, `buildTransaction`) are unaffected because `compile()` always returns `.legacy`.

- [x] **Task 3: Update deserialize() to parse V0 address lookup tables** (depends on Task 1)
  Files: `Sources/SolanaKit/Helper/SolanaSerializer.swift`
  Modify `deserialize(transactionData:)` (currently line 272):
  - Track the detected version: if the byte at cursor `>= 0x80` set `version = .v0` and consume the byte; otherwise `version = .legacy`. Currently this just does `cursor += 1` — now also record the version.
  - After parsing instructions, if `version == .v0` and bytes remain, parse the address lookup tables section (compact-u16 count, then for each: 32-byte public key + compact-u16 writable indexes + compact-u16 readonly indexes). For `.legacy`, set `addressLookupTables` to `[]`.
  - Construct `CompiledMessage` with the parsed `version` and `addressLookupTables`.
  - Existing `estimateFee()` callers are unaffected — they only read `header` and `instructions` from the returned message.

### Phase 2: Send Raw Transaction API

- [x] **Task 4: Add sendRawTransaction to TransactionManager**
  Files: `Sources/SolanaKit/Transactions/TransactionManager.swift`
  Add a new method `sendRawTransaction(rawTransaction: Data, signer: Signer) async throws -> FullTransaction` that mirrors Android `SolanaKit.sendRawTransaction()` (lines 215–243 of `SolanaKit.kt`):
  1. Deserialize the raw bytes via `SolanaSerializer.deserialize(transactionData:)` to get `(signatures, message)`.
  2. Re-serialize the message via `SolanaSerializer.serialize(message:)` — this produces the signable message bytes (including `0x80` prefix for V0 messages, thanks to Task 2).
  3. Sign the message bytes via `signer.sign(data: messageBytes)`.
  4. Replace the first signature slot (index 0) with the new signature. The deserialized `signatures` array has placeholder (all-zero) entries for each required signer — the fee payer's slot is always index 0.
  5. Re-serialize the full transaction via `SolanaSerializer.serialize(signatures: updatedSignatures, message: message)`.
  6. Base64-encode and broadcast via `rpcApiProvider.sendTransaction(serializedBase64:)`.
  7. Fetch a fresh blockhash via `rpcApiProvider.getLatestBlockhash()` for `lastValidBlockHeight` (needed for pending tx tracking, matches Android line 223).
  8. Estimate the fee via `ComputeBudgetProgram.calculateFee(from: message, baseFeeLamports: Kit.baseFeeLamports)`.
  9. Construct a pending `Transaction` record with `hash`, `timestamp`, `fee`, `from: address`, `to: nil`, `amount: nil`, `pending: true`, `blockHash`, `lastValidBlockHeight`, `base64Encoded` (the signed base64), `retryCount: 0`.
  10. Persist to storage and emit via `transactionsSubject` (same pattern as `sendSol`/`sendSpl`). Note: Android does NOT persist — but the iOS kit should, because `PendingTransactionSyncer` already handles retry via `base64Encoded` and this is a clean improvement over Android's behavior.
  11. Return the `FullTransaction`.

- [x] **Task 5: Expose sendRawTransaction on Kit** (depends on Task 4)
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Add a public method on `Kit`:
  ```swift
  public func sendRawTransaction(rawTransaction: Data, signer: Signer) async throws -> FullTransaction
  ```
  Delegates directly to `transactionManager.sendRawTransaction(rawTransaction:signer:)`, following the exact same delegation pattern as `sendSol` (line 197–198) and `sendSpl` (line 216–217).

## Commit Plan
- **Commit 1** (after tasks 1-3): "Add V0 versioned transaction serialization and deserialization support"
- **Commit 2** (after tasks 4-5): "Add sendRawTransaction API for broadcasting externally-built transactions"
