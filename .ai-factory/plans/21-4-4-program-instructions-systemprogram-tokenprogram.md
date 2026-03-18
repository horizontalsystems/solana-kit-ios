# Plan: Program Instructions — SystemProgram & TokenProgram

## Context

Implement instruction builder types for three Solana on-chain programs (`SystemProgram`, `TokenProgram`, `AssociatedTokenAccountProgram`) in a new `Programs/` directory. Android uses the SolanaKT library for these; there is no Swift equivalent, so they must be written from scratch. Each builder produces `TransactionInstruction` structs that feed into `SolanaSerializer.compile()`.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: System Program

- [x] **Task 1: Create `Programs/SystemProgram.swift`**
  Files: `Sources/SolanaKit/Programs/SystemProgram.swift`
  Create a caseless `enum SystemProgram` namespace (same style as `SolanaSerializer`). Implement one static method:

  ```swift
  static func transfer(from: PublicKey, to: PublicKey, lamports: UInt64) -> TransactionInstruction
  ```

  **Instruction data layout** (12 bytes total, little-endian):
  - Bytes 0–3: `UInt32(2)` — SystemProgram Transfer instruction index
  - Bytes 4–11: `UInt64` lamports amount

  **Account metas** (2 entries):
  1. `from` — `isSigner: true, isWritable: true`
  2. `to` — `isSigner: false, isWritable: true`

  **Program ID:** `PublicKey.systemProgramId` (already defined in `PublicKey.swift`).

  Use `var data = Data(count: 12)` and write with `withUnsafeBytes` / manual little-endian encoding (no `ByteBuffer` in Swift — use `UInt32(2).littleEndian` and `lamports.littleEndian`, then write raw bytes via `withUnsafeBytes(of:) { data.append(contentsOf: $0) }`).

### Phase 2: Token Programs

- [x] **Task 2: Create `Programs/TokenProgram.swift` and remove `Models/TokenProgram.swift`**
  Files: `Sources/SolanaKit/Programs/TokenProgram.swift`, `Sources/SolanaKit/Models/TokenProgram.swift`

  Create a caseless `enum TokenProgram` namespace with two static methods. Delete the existing `Models/TokenProgram.swift` (it only holds a redundant string constant — `PublicKey.tokenProgramId` already provides the same value).

  **Method 1 — `transfer`:**
  ```swift
  static func transfer(source: PublicKey, destination: PublicKey, authority: PublicKey, amount: UInt64) -> TransactionInstruction
  ```

  Instruction data (9 bytes, little-endian):
  - Byte 0: `UInt8(3)` — SPL Token Transfer instruction index
  - Bytes 1–8: `UInt64` amount

  Account metas (3 entries):
  1. `source` — `isSigner: false, isWritable: true`
  2. `destination` — `isSigner: false, isWritable: true`
  3. `authority` — `isSigner: true, isWritable: false`

  **Method 2 — `transferChecked`:**
  ```swift
  static func transferChecked(source: PublicKey, mint: PublicKey, destination: PublicKey, authority: PublicKey, amount: UInt64, decimals: UInt8) -> TransactionInstruction
  ```

  Instruction data (10 bytes, little-endian):
  - Byte 0: `UInt8(12)` — SPL Token TransferChecked instruction index
  - Bytes 1–8: `UInt64` amount
  - Byte 9: `UInt8` decimals

  Account metas (4 entries):
  1. `source` — `isSigner: false, isWritable: true`
  2. `mint` — `isSigner: false, isWritable: false`
  3. `destination` — `isSigner: false, isWritable: true`
  4. `authority` — `isSigner: true, isWritable: false`

  **Program ID:** `PublicKey.tokenProgramId`.

  Use the same little-endian byte-packing pattern as `SystemProgram`.

- [x] **Task 3: Create `Programs/AssociatedTokenAccountProgram.swift`**
  Files: `Sources/SolanaKit/Programs/AssociatedTokenAccountProgram.swift`

  Create a caseless `enum AssociatedTokenAccountProgram` namespace with one instruction builder and one PDA helper.

  **Static helper — `associatedTokenAddress`:**
  ```swift
  static func associatedTokenAddress(wallet: PublicKey, mint: PublicKey) throws -> PublicKey
  ```
  Derives the ATA address using `PublicKey.findProgramAddress(seeds:programId:)` with seeds `[wallet.data, PublicKey.tokenProgramId.data, mint.data]` and program ID `PublicKey.associatedTokenProgramId`. Returns just the `PublicKey` (discards the bump). This mirrors Android's `PublicKey.associatedTokenAddress(walletAddress:tokenMintAddress:)`.

  **Instruction builder — `createIdempotent`:**
  ```swift
  static func createIdempotent(payer: PublicKey, associatedToken: PublicKey, owner: PublicKey, mint: PublicKey) -> TransactionInstruction
  ```

  Instruction data: single byte `Data([1])` — the `CreateIdempotent` instruction discriminator (instruction index 1). Unlike the original `Create` (index 0, empty data), the idempotent variant succeeds silently if the ATA already exists.

  Account metas (7 entries):
  1. `payer` — `isSigner: true, isWritable: true` (pays rent)
  2. `associatedToken` — `isSigner: false, isWritable: true` (the ATA to create)
  3. `owner` — `isSigner: false, isWritable: false` (wallet that owns the ATA)
  4. `mint` — `isSigner: false, isWritable: false`
  5. `PublicKey.systemProgramId` — `isSigner: false, isWritable: false`
  6. `PublicKey.tokenProgramId` — `isSigner: false, isWritable: false`
  7. `PublicKey.sysvarRentProgramId` — `isSigner: false, isWritable: false`

  **Program ID:** `PublicKey.associatedTokenProgramId`.

### Phase 3: Cleanup

- [x] **Task 4: Verify build and fix any references to old `Models/TokenProgram`**
  Files: any file importing or referencing `TokenProgram.programId` (the old string constant)

  After deleting `Models/TokenProgram.swift` in Task 2, run `swift build` and fix any compilation errors. Known usages of the old `TokenProgram.programId` string constant exist in `TransactionSyncer.swift` (for filtering mint accounts by program owner). Replace those references with `PublicKey.tokenProgramId.base58` (the Base58 string from the `PublicKey` constant). Confirm the build succeeds cleanly.
