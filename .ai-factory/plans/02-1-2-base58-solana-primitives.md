# Plan: Base58 & Solana Primitives

## Context

Implement the foundational encoding utilities and the `PublicKey` value type that every subsequent milestone depends on — Base58 encoding/decoding, Solana's compact-u16 variable-length integer format, and a 32-byte `PublicKey` wrapper with Base58 string representation, GRDB persistence, and Codable support.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Encoding Utilities

- [x] **Task 1: Base58 encoder/decoder**
  Files: `Sources/SolanaKit/Helper/Base58.swift`
  Create a new `Helper/` directory under `Sources/SolanaKit/` (following EvmKit.Swift's `Helper/` pattern for encoding utilities like `RLP.swift`). Implement `enum Base58` as a caseless enum namespace with two static methods:
  - `static func encode(_ data: Data) -> String` — encodes arbitrary bytes to a Base58 string using the standard Bitcoin alphabet (`123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`). Must handle leading zero bytes (map to leading `1` characters).
  - `static func decode(_ string: String) throws -> Data` — decodes a Base58 string back to bytes. Throws on invalid characters.
  - Define a nested `enum Base58Error: Error` (or `Base58DecodingError`) with at least `.invalidCharacter` case.
  - Algorithm: standard big-integer base conversion. The Android kit uses `org.sol4k.Base58` and `org.bitcoinj.core.Base58` — both implement the same canonical algorithm. Port the encode/decode logic (count leading zeros, base-256 ↔ base-58 conversion using a byte accumulator). No checksum (Solana uses raw Base58, not Base58Check).
  - Mark the enum and its methods as `internal` (not `public` — only `Kit` and `Signer` are public per architecture rules).

- [x] **Task 2: Compact-u16 encoder/decoder**
  Files: `Sources/SolanaKit/Helper/CompactU16.swift`
  Implement `enum CompactU16` as a caseless enum namespace with two static methods:
  - `static func encode(_ value: Int) -> Data` — encodes an integer (0–65535) as 1–3 bytes using Solana's compact-u16 format. Algorithm: take lowest 7 bits, if more bits remain set the continuation bit (0x80) and repeat. Port directly from `org.sol4k.Binary.encodeLength()`.
  - `static func decode(_ data: Data) -> (value: Int, bytesRead: Int)` — decodes compact-u16 from the start of a byte buffer. Returns the decoded value and how many bytes were consumed. Port from `org.sol4k.Binary.decodeLength()`.
  - Mark as `internal`.
  - This encoding is used in transaction serialization (milestone 4.3) for every array length field: signature count, account key count, instruction count, instruction data length, address lookup table counts.

### Phase 2: PublicKey Type

- [x] **Task 3: PublicKey value type**
  Files: `Sources/SolanaKit/Models/PublicKey.swift`
  Implement `struct PublicKey` as the unified Solana public key type (replacing the two separate `PublicKey` types in Android — `com.solana.core.PublicKey` and `org.sol4k.PublicKey`). Follow EvmKit's `Address.swift` patterns for conformances:

  **Storage:** `let data: Data` (exactly 32 bytes).

  **Initializers:**
  - `init(data: Data) throws` — validates that `data.count == 32`, throws `PublicKey.Error.invalidPublicKeyLength` otherwise.
  - `init(_ base58String: String) throws` — decodes via `Base58.decode()`, then calls `init(data:)`. Throws on invalid Base58 or wrong length.

  **Properties and methods:**
  - `var base58: String` — returns `Base58.encode(data)`. This is the primary string representation.
  - `var bytes: Data` — alias for `data` (mirrors Android's `toByteArray()` / `bytes()`).

  **Protocol conformances (all in extensions at the bottom of the file, following EvmKit pattern):**
  - `Equatable` — compare `data` byte-for-byte (synthesized is fine since `Data` is `Equatable`).
  - `Hashable` — hash `data` (synthesized is fine).
  - `CustomStringConvertible` — `description` returns `base58`.
  - `DatabaseValueConvertible` (GRDB) — stored as a 32-byte blob, matching EvmKit's `Address` pattern: `databaseValue` returns `data.databaseValue`; `fromDatabaseValue` matches `.blob(data)` and constructs via `try? PublicKey(data: data)`.
  - `Codable` — custom `init(from:)` decodes a `String` from the single-value container and calls `try PublicKey(base58String)`. `encode(to:)` writes `base58` as a string. This handles JSON-RPC responses where public keys are Base58 strings.

  **Error type:** `enum PublicKey.Error: Swift.Error` with cases `.invalidPublicKeyLength`, `.invalidBase58String`.

  **Well-known constants (static):** Add a few common program IDs as static constants for convenience (used in later milestones):
  - `static let systemProgramId = try! PublicKey("11111111111111111111111111111111")`
  - `static let tokenProgramId = try! PublicKey("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")`
  - `static let associatedTokenProgramId = try! PublicKey("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")`
  - `static let sysvarRentProgramId = try! PublicKey("SysvarRent111111111111111111111111111111111")`
  - `static let computeBudgetProgramId = try! PublicKey("ComputeBudget111111111111111111111111111111")`

  **Not in scope for this milestone:** `findProgramAddress` and `associatedTokenAddress` derivation — those require SHA-256 and Ed25519 curve checks, and will be added in milestone 4.4 when program instructions are implemented.

- [x] **Task 4: Remove scaffold placeholder**
  Files: `Sources/SolanaKit/SolanaKit.swift`
  Delete the placeholder file `Sources/SolanaKit/SolanaKit.swift` (it contains only a 2-line comment and was created in milestone 1.1 solely to make the empty package compile). The package now has real source files from Tasks 1–3 and no longer needs it. Verify the package compiles cleanly with `swift build`.
