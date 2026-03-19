## Code Review Summary

**Files Reviewed:** 5
- `Sources/SolanaKit/Helper/SolanaSerializer.swift` (515 lines — core serializer)
- `Sources/SolanaKit/Models/AccountMeta.swift` (12 lines — value type)
- `Sources/SolanaKit/Models/TransactionInstruction.swift` (16 lines — value type)
- `Sources/SolanaKit/Helper/CompactU16.swift` (dependency — compact-u16 codec)
- `Sources/SolanaKit/Helper/Base58.swift` (dependency — Base58 codec)

**Risk Level:** :green_circle: Low

### Context Gates

- **ARCHITECTURE.md:** WARN — `SolanaSerializer` lives in `Helper/` which is not explicitly listed in the architecture folder structure (`Core/`, `Api/`, `Transactions/`, `Database/`, `Models/`). However, it follows the EvmKit `Helper/RLP.swift` pattern referenced in the plan and CLAUDE.md. The caseless-enum-as-namespace pattern is consistent with the project's conventions. No dependency rule violations — `Helper/` types only depend on `Models/` types (`PublicKey`, `AccountMeta`, `TransactionInstruction`) and other helpers (`Base58`, `CompactU16`).
- **RULES.md:** No file present — WARN (non-blocking).
- **ROADMAP.md:** Milestone 4.3 is tracked and marked complete. Implementation matches scope: legacy transaction serialization + convenience methods. The code also includes V0 versioned transaction support and deserialization, which belong to milestone 5.1 — this is forward-compatible and non-blocking.

### Critical Issues

None.

### Suggestions

1. **UInt8 overflow in `compile()` will trap on >255 unique accounts** (SolanaSerializer.swift:168-169, 161-163)

   The `UInt8(idx)` conversion in the key-index lookup table and `UInt8(groupA.count + groupB.count)` in the header will trigger a Swift arithmetic overflow trap if a caller passes instructions referencing more than 255 unique accounts. While Solana's 1232-byte MTU limits real transactions to ~35 accounts, a library should throw a descriptive error rather than crash on invalid input:

   ```swift
   // Before building the lookup table (around line 167):
   guard accountKeys.count <= 256 else {
       throw SerializerError.invalidTransactionData(
           "Transaction references \(accountKeys.count) unique accounts, exceeds maximum of 256"
       )
   }
   ```

2. **`serialize(signatures:message:)` does not validate signature count vs header** (SolanaSerializer.swift:299-313)

   The method validates each signature is 64 bytes but does not check that `signatures.count == message.header.numRequiredSignatures`. A mismatch produces a wire-format transaction the RPC will reject. Adding a guard gives callers an immediate, descriptive error instead of a cryptic RPC failure:

   ```swift
   guard signatures.count == Int(message.header.numRequiredSignatures) else {
       throw SerializerError.invalidSignatureLength(signatures.count)
       // (or a dedicated error case like .signatureCountMismatch)
   }
   ```

3. **`buildTransaction()` recompiles the message unnecessarily** (SolanaSerializer.swift:506-514)

   The documented single-signer flow calls `serializeMessage()` (which runs `compile()` + `serialize(message:)`) then `buildTransaction()` (which runs `compile()` again). This doubles the compilation work. Consider exposing a variant that accepts a pre-compiled `CompiledMessage`:

   ```swift
   static func buildTransaction(signatures: [Data], message: CompiledMessage) throws -> Data {
       return try serialize(signatures: signatures, message: message)
   }
   ```

   This already exists as `serialize(signatures:message:)`, so the fix is just updating the docstring on `buildTransaction` to recommend calling `compile()` once and reusing the result, or adding a note that the two-call pattern (`serializeMessage` then `buildTransaction`) intentionally re-compiles for API simplicity.

4. **`CompactU16.decode` silently produces wrong values on truncated multi-byte encodings** (CompactU16.swift:28-42)

   If the input data is truncated mid-encoding (e.g., first byte has continuation bit `0x80` but no second byte follows), the `for byte in data` loop terminates early and returns an incorrect value with `bytesRead > 0`. The `readCompactU16()` helper in `SolanaSerializer.deserialize()` cannot detect this silent corruption. Consider adding a check after the loop:

   ```swift
   // After the for loop:
   if bytesRead > 0 && data[data.index(data.startIndex, offsetBy: bytesRead - 1)] & 0x80 != 0 {
       return (value: 0, bytesRead: 0)  // signal failure — truncated encoding
   }
   ```

   This is a deserialization-only concern and does not affect the serialization path.

### Positive Notes

- **Correct account-key ordering** — the four-group partition (writable-signers, readonly-signers, writable-non-signers, readonly-non-signers) with fee-payer pinned at index 0 precisely matches the Solana runtime specification.
- **Clean caseless-enum namespace** — follows the EvmKit `RLP` pattern exactly as planned. No instances possible, pure static API.
- **Thorough deserialization** — the cursor-based `deserialize()` method with inner `read()` and `readCompactU16()` helpers is well-structured, with proper bounds checking at every step.
- **Forward-compatible V0 support** — the implementation already handles versioned transactions (V0 prefix byte, address lookup tables) in both serialization and deserialization, enabling milestone 5.1 without rework.
- **Good error types** — `SerializerError` cases carry context (the invalid blockhash string, the wrong signature length, the missing public key) making debugging straightforward.
- **Thread-safe by design** — all methods are static with no shared mutable state; safe to call from any context.
- **Architecture compliance** — `AccountMeta` and `TransactionInstruction` are pure value types in `Models/` with zero dependencies on other layers. `SolanaSerializer` depends only on `Models/` and other helpers. No architecture boundary violations.
