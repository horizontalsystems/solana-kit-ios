## Code Review Summary

**Files Reviewed:** 5
- `Sources/SolanaKit/Programs/ComputeBudgetProgram.swift`
- `Sources/SolanaKit/Transactions/TransactionManager.swift`
- `Sources/SolanaKit/Core/Kit.swift`
- `Sources/SolanaKit/Programs/AssociatedTokenAccountProgram.swift`
- `Sources/SolanaKit/Helper/SolanaSerializer.swift`

**Risk Level:** 🟡 Medium

### Context Gates

- **ARCHITECTURE.md:** WARN — Architecture document describes `Kit` as never touching key material ("Kit never touches key material; it only accepts pre-signed serialized bytes"), but the current implementation passes a `Signer` through `Kit.sendSol`/`Kit.sendSpl` all the way to `TransactionManager` where signing happens. This is a documentation inconsistency rather than a code bug — the actual pattern matches Android's approach and is pragmatic. The architecture doc's Signer section example code is aspirational, not descriptive of the current design.
- **RULES.md:** No file present — WARN (non-blocking).
- **ROADMAP.md:** Milestone 4.5 is marked `[x]` in the roadmap. Implementation aligns with the described scope.

### Critical Issues

None.

### Suggestions

1. **Double compilation in `serializeSignAndSend`** (`TransactionManager.swift` lines 516-537)

   The helper calls `SolanaSerializer.serializeMessage()` (which internally calls `compile()`) and then `SolanaSerializer.buildTransaction()` (which also calls `compile()` with the same inputs). The instruction set is compiled twice — unnecessary work. `SolanaSerializer.buildTransaction`'s own doc comment warns about this:

   > "If you need the message bytes for signing first, use `compile()` + `serialize(message:)` + `serialize(signatures:message:)` directly to avoid compiling twice."

   Suggested fix:
   ```swift
   private func serializeSignAndSend(
       feePayer: PublicKey,
       instructions: [TransactionInstruction],
       recentBlockhash: String,
       signer: Signer
   ) async throws -> (base64Tx: String, txHash: String) {
       let message = try SolanaSerializer.compile(
           feePayer: feePayer,
           instructions: instructions,
           recentBlockhash: recentBlockhash
       )
       let messageBytes = SolanaSerializer.serialize(message: message)
       let signature = try signer.sign(data: messageBytes)
       let txData = try SolanaSerializer.serialize(signatures: [signature], message: message)
       let base64Tx = txData.base64EncodedString()
       let txHash = try await rpcApiProvider.sendTransaction(serializedBase64: base64Tx)
       return (base64Tx, txHash)
   }
   ```

   This avoids re-compiling the instruction set and is consistent with the serializer's documented recommended usage pattern.

### Positive Notes

- **Clean DRY structure**: `priorityFeeInstructions()` and `serializeSignAndSend()` helpers eliminate duplication between `sendSol`, `sendSpl`, and leave a clear extension point for future send methods.
- **Correct ComputeBudgetProgram types**: Uses `UInt32` for compute unit limit (5-byte instruction data) matching the actual Solana on-chain program spec, improving on Android's `Long`-based approach which allocates 9 bytes (the extra 4 zero bytes happen to be ignored by the runtime).
- **Race-safe ATA creation**: Using `createIdempotent` for the recipient's ATA means the transaction succeeds even if the ATA is created between the existence check and broadcast.
- **Defensive MintAccount fallback** in `sendSpl` (line 397): If the stored `MintAccount` is missing, one is constructed from `TokenAccount.decimals` — ensures the `FullTokenTransfer` is always well-formed.
- **Thread safety**: All `transactionsSubject.send()` calls are dispatched on `DispatchQueue.main`, consistent with the architecture's requirement.
- **Bonus parsing/fee methods**: `ComputeBudgetProgram.parseComputeUnitLimit/Price` and `calculateFee` add useful introspection capability used by `sendRawTransaction` and `Kit.estimateFee` — well-designed additions beyond the plan scope.
- **Same-address guard** in `sendSpl` (line 336): Prevents self-transfers with a clear error, matching Android behavior.

REVIEW_PASS
