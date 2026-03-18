# Review: 1.2 Base58 & Solana Primitives

**Date:** 2026-03-18
**Files reviewed:** `Base58.swift`, `CompactU16.swift`, `PublicKey.swift`, `Package.swift` (diff), deleted `SolanaKit.swift`
**Build status:** BUILD SUCCEEDED (xcodebuild, iOS Simulator iPhone 17)
**Reference checked:** Android `Address.kt`, `SolanaKit.kt` imports of `org.sol4k.Base58` / `org.sol4k.Binary`

---

## Critical Issues

None.

## High-Severity Issues

None.

## Medium-Severity Issues

### M1: `CompactU16.decode` returns `bytesRead: 0` on empty data
**File:** `CompactU16.swift:27`
**Problem:** If called with empty `Data`, the for loop never executes and the function returns `(value: 0, bytesRead: 0)`. Any caller that advances through a buffer using `bytesRead` as the offset increment will infinite-loop.
**Suggested fix:** Either return a sentinel/throw, or add a `guard !data.isEmpty` precondition. Since this is internal, a `precondition(!data.isEmpty)` is appropriate — it would crash in debug and signal a programming error rather than silently producing a 0-advance.

### M2: `CompactU16.encode` accepts out-of-range values silently
**File:** `CompactU16.swift:10`
**Problem:** The doc says 0–65535, but negative `Int` values would produce garbage (right-shifting a negative value in Swift is arithmetic, so the loop may not terminate on some platforms), and values > 65535 produce >3 bytes which violates the Solana compact-u16 spec. Since this is internal, the risk is low, but a `precondition(value >= 0 && value <= 65535)` would prevent subtle serialization bugs later.

## Low-Severity / Informational

### L1: `Base58` decoding table uses `Character` keys
**File:** `Base58.swift:10`
`Character` comparisons involve grapheme cluster normalization, which is heavier than a `UInt8` lookup table. For Solana keys (~44 chars) the performance difference is negligible. Not actionable now, but if Base58 ever becomes a hot path (batch transaction parsing), switching to a `[UInt8: UInt8]` table or a 128-element `[Int]` array would be faster.

### L2: `swift build` fails on macOS host
**Problem:** `swift build` (which targets the host macOS platform) fails because `HsToolKit` → `ObjectMapper` requires macOS 12.0. This is a pre-existing dependency constraint from milestone 1.1, not introduced here. The package builds fine for iOS targets via `xcodebuild`. No action needed for this milestone.

### L3: Explicit `Equatable`/`Hashable` implementations are redundant
**File:** `PublicKey.swift:69-79`
`PublicKey` is a struct with a single `Data` property. Swift can auto-synthesize both conformances. The explicit implementations do the same thing. Not wrong, just unnecessary code. Purely cosmetic.

## Correctness Verification

### Base58
- **Algorithm:** Standard big-integer base conversion (base-256 ↔ base-58). Matches the canonical Bitcoin/sol4k algorithm.
- **Alphabet:** `123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz` — correct (58 chars, no 0/O/I/l).
- **Leading zeros:** Encode maps leading 0x00 bytes to leading `1` chars; decode reverses this. Correct.
- **Empty input:** `encode(Data())` → `""`, `decode("")` → `Data()`. Round-trips correctly.
- **No checksum:** Correct for Solana (raw Base58, not Base58Check).

### CompactU16
- **Algorithm:** Standard unsigned LEB128, limited to u16 range. Matches sol4k's `Binary.encodeLength()` / `decodeLength()`.
- **encode(0)** → `[0x00]` (1 byte). Correct.
- **encode(127)** → `[0x7F]` (1 byte). Correct.
- **encode(128)** → `[0x80, 0x01]` (2 bytes). Correct.
- **encode(16383)** → `[0xFF, 0x7F]` (2 bytes). Correct.
- **encode(16384)** → `[0x80, 0x80, 0x01]` (3 bytes). Correct.
- **encode(65535)** → `[0xFF, 0xFF, 0x03]` (3 bytes). Correct.
- **Round-trip:** All above values decode back correctly.

### PublicKey
- **32-byte validation:** Enforced in `init(data:)`. Correct.
- **Base58 init:** Decodes then validates length. `Base58.Error.invalidCharacter` is caught and re-wrapped as `PublicKey.Error.invalidBase58String`; `invalidPublicKeyLength` propagates directly. Error handling is precise.
- **Well-known constants:** All are established Solana program IDs. `systemProgramId` = 32 `1`s → 32 zero bytes. Verified correct.
- **GRDB conformance:** Stores as blob, restores from blob. Matches EvmKit `Address` pattern.
- **Codable conformance:** Encodes/decodes as Base58 string. Wraps errors in `DecodingError.dataCorruptedError`. Matches Solana JSON-RPC format.
- **Android parity:** iOS `PublicKey` unifies Android's two separate types (`com.solana.core.PublicKey` + `org.sol4k.PublicKey`) and the `Address` wrapper. Simpler and cleaner.

### Package.swift
- **iOS 14 minimum:** Reasonable. Dependencies and future `NWPathMonitor` usage are compatible.

## Summary

Clean implementation. All three types are algorithmically correct and match the Android reference. Two medium-severity defensive coding gaps in `CompactU16` (empty data and out-of-range values) — both are internal-only and low risk, but worth adding preconditions to prevent subtle bugs in future transaction serialization code.

REVIEW_PASS
