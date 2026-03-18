# Plan: Priority Fees & Retry Logic

## Context

Add `ComputeBudgetProgram` instructions for priority fees, transaction retry on blockhash expiry, and fee estimation for externally-built (raw) transactions. In Android this was a separate commit layered on top of the basic send flow; in the iOS port the priority fee injection and retry logic were already included during initial implementation. The remaining work is **fee estimation** — parsing a serialized transaction to extract compute budget parameters and calculate the total fee.

**Already implemented (no work needed):**
- `ComputeBudgetProgram.swift` — `setComputeUnitLimit(units:)` and `setComputeUnitPrice(microLamports:)` instruction builders
- `TransactionManager.priorityFeeInstructions()` — hardcoded 300,000 CU limit + 500,000 microLamports/CU, prepended to both `sendSol` and `sendSpl`
- `PendingTransactionSyncer.swift` — full retry loop: polls pending transactions each block-height tick, re-broadcasts while blockhash valid, marks failed on expiry
- `Transaction` model stores `blockHash`, `lastValidBlockHeight`, `base64Encoded`, `retryCount`
- `Kit.fee` (0.000155 SOL) and `Kit.baseFeeLamports` (5000) static constants

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Transaction Deserialization

- [x] **Task 1: Add transaction deserialization to SolanaSerializer**
  Files: `Sources/SolanaKit/Helper/SolanaSerializer.swift`
  Add a `static func deserialize(transactionData: Data) throws -> (signatures: [Data], message: CompiledMessage)` method that parses a wire-format transaction back into its constituent parts. This is the reverse of the existing `serialize(signatures:message:)` method.

  The parser must handle two formats:
  - **Legacy transactions** (no version prefix): starts directly with compact-u16 signature count, followed by signatures (64 bytes each), then the message bytes (header + account keys + blockhash + instructions — same layout documented in `serialize(message:)`).
  - **Versioned v0 transactions** (prefix byte `0x80`): identical layout except the message starts with a version byte (`0x80` = v0) and may have an address lookup table section appended after the instructions. For fee estimation purposes, the lookup table section can be skipped — only the header, account keys, and instructions need to be parsed.

  Detection: if the first byte after signatures is `< 0x80`, it is a legacy message (that byte is `numRequiredSignatures`, always small). If `>= 0x80`, mask off the high bit to get the version number (0 for v0).

  Use the existing `CompactU16.decode(_:)` helper for variable-length integers. Add a new error case `SerializerError.invalidTransactionData(String)` for malformed input.

  Reference: the existing `serialize(message:)` method (line 197) documents the exact wire layout to reverse.

### Phase 2: Fee Estimation

- [x] **Task 2: Add ComputeBudget instruction parser**
  Files: `Sources/SolanaKit/Programs/ComputeBudgetProgram.swift`
  Add two static parsing methods to extract compute budget parameters from compiled instructions:

  ```swift
  static func parseComputeUnitLimit(from compiledMessage: SolanaSerializer.CompiledMessage) -> UInt32?
  static func parseComputeUnitPrice(from compiledMessage: SolanaSerializer.CompiledMessage) -> UInt64?
  ```

  Each method iterates `compiledMessage.instructions`, checks whether `compiledMessage.accountKeys[instruction.programIdIndex]` equals `.computeBudgetProgramId`, then reads the discriminator byte:
  - `0x02` → read the next 4 bytes as little-endian `UInt32` (compute unit limit)
  - `0x03` → read the next 8 bytes as little-endian `UInt64` (compute unit price in microLamports)

  Return `nil` if no matching instruction is found (transaction has no priority fee).

  Also add a convenience method that calculates the total fee:
  ```swift
  static func calculateFee(from compiledMessage: SolanaSerializer.CompiledMessage, baseFeeLamports: Int64) -> Decimal
  ```
  Formula: `baseFee + (computeUnitPrice * computeUnitLimit / 1_000_000)` converted to SOL by dividing by `1_000_000_000`. If no compute budget instructions are found, return just the base fee converted to SOL. Mirrors Android `VersionedTransaction.calculateFee(baseFeeLamports)`.

- [x] **Task 3: Add `Kit.estimateFee(rawTransaction:)` public method**
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Add a public method to `Kit`:

  ```swift
  public static func estimateFee(rawTransaction: Data) throws -> Decimal
  ```

  Implementation:
  1. Call `SolanaSerializer.deserialize(transactionData: rawTransaction)` to parse the transaction.
  2. Call `ComputeBudgetProgram.calculateFee(from: message, baseFeeLamports: baseFeeLamports)` to compute the total fee.
  3. Return the fee as a `Decimal` in SOL units.

  This is a `static` method (does not require a `Kit` instance) — mirrors Android's `SolanaKit.estimateFee(hexEncoded:)` which is called from `BaseSolanaAdapter` when displaying fees for swap/Jupiter transactions.

  Note: the Android version receives `hexEncoded: ByteArray` and converts to base64 internally. The iOS version should accept raw `Data` (already decoded bytes) since the caller can handle encoding conversion. Add an overload that accepts a base64 string for convenience:

  ```swift
  public static func estimateFee(base64EncodedTransaction: String) throws -> Decimal
  ```
