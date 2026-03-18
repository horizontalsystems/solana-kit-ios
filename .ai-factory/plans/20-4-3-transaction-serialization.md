# Plan: Transaction Serialization

## Context
Implement Solana legacy transaction serialization from scratch in `Helper/SolanaSerializer.swift`, following EvmKit's `Helper/RLP.swift` pattern (caseless `enum` as a pure static namespace). This produces the binary wire format (`Data`) needed for Ed25519 signing and JSON-RPC broadcast. The serializer compiles high-level instructions into a Solana Message (header + ordered account keys + recent blockhash + compiled instructions using compact-u16 arrays), then wraps signatures + message into the full Transaction wire format. Android delegates this to the `SolanaKT`/`sol4k` libraries — no Swift equivalent exists, so this is a custom implementation.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Input Model Types

- [x] **Task 1: Create AccountMeta and TransactionInstruction structs**
  Files: `Sources/SolanaKit/Models/AccountMeta.swift`, `Sources/SolanaKit/Models/TransactionInstruction.swift`

  Create two pure value types in Models/ (no dependencies on other layers, per architecture rules):

  **`AccountMeta.swift`** — represents a single account reference in an instruction:
  ```swift
  struct AccountMeta: Equatable, Hashable {
      let publicKey: PublicKey
      let isSigner: Bool
      let isWritable: Bool
  }
  ```
  Must be `Hashable` via `publicKey` so the serializer can deduplicate accounts efficiently.

  **`TransactionInstruction.swift`** — represents a single uncompiled instruction:
  ```swift
  struct TransactionInstruction {
      let programId: PublicKey
      let keys: [AccountMeta]    // ordered account metas
      let data: Data             // arbitrary instruction data bytes
  }
  ```
  These types mirror the Android `TransactionInstruction` / `AccountMeta` from SolanaKT and are the input to the serializer's `compile()` method. They will also be used by program builders (SystemProgram, TokenProgram) in later milestones.

### Phase 2: Serializer Implementation

- [x] **Task 2: Create SolanaSerializer enum with nested types and message compilation**
  Files: `Sources/SolanaKit/Helper/SolanaSerializer.swift`

  Create a caseless `enum SolanaSerializer` (matching the EvmKit `enum RLP` pattern — pure namespace, no instances). Define nested types and the core compilation logic:

  **Nested types** (internal to the module, not `public`):
  ```swift
  enum SolanaSerializer {
      struct MessageHeader {
          let numRequiredSignatures: UInt8
          let numReadonlySignedAccounts: UInt8
          let numReadonlyUnsignedAccounts: UInt8
      }

      struct CompiledInstruction {
          let programIdIndex: UInt8
          let accountIndices: [UInt8]
          let data: Data
      }

      struct CompiledMessage {
          let header: MessageHeader
          let accountKeys: [PublicKey]       // ordered: writable-signers, readonly-signers, writable-non-signers, readonly-non-signers
          let recentBlockhash: Data          // 32 bytes, decoded from Base58
          let instructions: [CompiledInstruction]
      }
  }
  ```

  **Compilation method** — the most complex part, implements account key deduplication and ordering:
  ```swift
  static func compile(feePayer: PublicKey, instructions: [TransactionInstruction], recentBlockhash: String) throws -> CompiledMessage
  ```

  Implementation steps (must match Solana runtime expectations exactly):
  1. Collect all unique `PublicKey`s from: fee payer, all instruction `keys[].publicKey`, all instruction `programId`s.
  2. For each unique key, track whether it appears as a signer and/or writable across any instruction. The fee payer is always both signer and writable. Program IDs are neither signer nor writable (read-only, non-signer).
  3. Sort into four groups in this exact order:
     - Group A: writable signers (fee payer always first within this group)
     - Group B: readonly signers
     - Group C: writable non-signers
     - Group D: readonly non-signers
  4. Build the `MessageHeader`: `numRequiredSignatures = |A| + |B|`, `numReadonlySignedAccounts = |B|`, `numReadonlyUnsignedAccounts = |D|`.
  5. Build a lookup dictionary `PublicKey → index` from the ordered account keys array.
  6. Compile each `TransactionInstruction` into a `CompiledInstruction`: resolve `programId` and each `keys[].publicKey` to their index in the account keys array.
  7. Decode `recentBlockhash` from Base58 string to 32-byte `Data` using the existing `Base58.decode()`.
  8. Return the assembled `CompiledMessage`.

  Throw a descriptive error if Base58 decoding fails or if the blockhash is not exactly 32 bytes.

- [x] **Task 3: Implement message serialization**
  Files: `Sources/SolanaKit/Helper/SolanaSerializer.swift` (same file, add method)

  Add to `SolanaSerializer`:
  ```swift
  static func serialize(message: CompiledMessage) -> Data
  ```

  Encodes the compiled message into Solana's wire format. Use the existing `CompactU16.encode()` for array lengths. The exact byte layout:
  ```
  [1 byte]  header.numRequiredSignatures
  [1 byte]  header.numReadonlySignedAccounts
  [1 byte]  header.numReadonlyUnsignedAccounts
  [compact-u16]  accountKeys.count
  [32 bytes each]  accountKeys — raw PublicKey.data bytes, in order
  [32 bytes]  recentBlockhash — raw bytes (already decoded in CompiledMessage)
  [compact-u16]  instructions.count
  [for each CompiledInstruction]:
      [1 byte]  programIdIndex
      [compact-u16]  accountIndices.count
      [1 byte each]  accountIndices
      [compact-u16]  data.count
      [N bytes]  data
  ```

  Build the result by appending into a `var result = Data()` — use `result.append(byte)` for single bytes, `result.append(contentsOf:)` for arrays, `result.append(CompactU16.encode(count))` for compact-u16 lengths. This is the exact data that `Signer.sign(data:)` will receive.

- [x] **Task 4: Implement transaction serialization and convenience method**
  Files: `Sources/SolanaKit/Helper/SolanaSerializer.swift` (same file, add methods)

  Add two methods to `SolanaSerializer`:

  **Transaction wire format serialization:**
  ```swift
  static func serialize(signatures: [Data], message: CompiledMessage) -> Data
  ```
  Encodes the full transaction for broadcast:
  ```
  [compact-u16]  signatures.count
  [64 bytes each]  signatures — raw Ed25519 signature bytes
  [message bytes]  serialize(message:) output
  ```
  Each signature must be exactly 64 bytes; assert or throw if not.

  **End-to-end convenience method:**
  ```swift
  static func buildTransaction(feePayer: PublicKey, instructions: [TransactionInstruction], recentBlockhash: String, signatures: [Data]) throws -> Data
  ```
  Combines compile + serialize in one call: `compile() → serialize(signatures:message:)`. This is the primary entry point for callers building a signed transaction — they compile with the fee payer and instructions, sign the serialized message bytes externally via `Signer`, then pass the signature(s) back here to get the final wire-format `Data` ready for base64 encoding and broadcast via `SendTransactionJsonRpc`.

  Also add a helper for the common single-signer case:
  ```swift
  static func serializeMessage(feePayer: PublicKey, instructions: [TransactionInstruction], recentBlockhash: String) throws -> Data
  ```
  Compiles and serializes just the message (no signatures). Returns the `Data` that the caller passes to `Signer.sign(data:)`. This separates the "build the signable payload" step from the "wrap with signatures" step, matching the `Signer` decoupling pattern from the architecture.
