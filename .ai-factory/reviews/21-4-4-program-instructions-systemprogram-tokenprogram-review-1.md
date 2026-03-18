# Review: 4.4 Program Instructions — SystemProgram & TokenProgram

**Date:** 2026-03-18
**Scope:** 3 new files in `Programs/`, 1 deleted file in `Models/`, 1 modified RPC file

## Files Reviewed

| File | Status |
|------|--------|
| `Sources/SolanaKit/Programs/SystemProgram.swift` | New |
| `Sources/SolanaKit/Programs/TokenProgram.swift` | New |
| `Sources/SolanaKit/Programs/AssociatedTokenAccountProgram.swift` | New |
| `Sources/SolanaKit/Models/TokenProgram.swift` | Deleted |
| `Sources/SolanaKit/Api/JsonRpc/GetTokenAccountsByOwnerJsonRpc.swift` | Modified |

## Specification Correctness

### SystemProgram.transfer
- Instruction index `UInt32(2)` — correct (SystemInstruction enum: 0=CreateAccount, 1=Assign, 2=Transfer)
- 4-byte LE discriminator + 8-byte LE u64 = 12 bytes total — correct
- Account metas: from (signer+writable), to (non-signer+writable) — correct
- Program ID: `.systemProgramId` (11111111111111111111111111111111) — correct

### TokenProgram.transfer
- Instruction index `UInt8(3)` — correct (SPL Token: 3=Transfer)
- 1-byte discriminator + 8-byte LE u64 = 9 bytes total — correct
- Account metas: source (writable), destination (writable), authority (signer) — correct order and flags
- Program ID: `.tokenProgramId` — correct

### TokenProgram.transferChecked
- Instruction index `UInt8(12)` — correct (SPL Token: 12=TransferChecked)
- 1-byte discriminator + 8-byte LE u64 + 1-byte decimals = 10 bytes total — correct
- Account metas: source (writable), mint (read-only), destination (writable), authority (signer) — correct order and flags
- Program ID: `.tokenProgramId` — correct

### AssociatedTokenAccountProgram.associatedTokenAddress
- Seeds: `[wallet.data, tokenProgramId.data, mint.data]` with `associatedTokenProgramId` — correct PDA derivation
- Matches Android `PublicKey.associatedTokenAddress(walletAddress:tokenMintAddress:)` — verified

### AssociatedTokenAccountProgram.createIdempotent
- Instruction data `Data([1])` — correct (0=Create, 1=CreateIdempotent)
- 7 account metas in correct order: payer (signer+writable), ATA (writable), owner, mint, SystemProgram, TokenProgram, SysvarRent — all correct
- Program ID: `.associatedTokenProgramId` — correct

### Discriminator size difference
SystemProgram uses a 4-byte `UInt32` discriminator while TokenProgram uses a 1-byte `UInt8`. This is correct — the two programs use different discriminator widths in the Solana specification. Not a bug.

## Deletion of Models/TokenProgram.swift

The deleted file contained only `static let programId = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"`. This value is already available as `PublicKey.tokenProgramId.base58`. Grep confirmed zero remaining references to `TokenProgram.programId` in Swift source. The new `Programs/TokenProgram.swift` replaces the enum name with instruction-builder methods — no naming conflict since the old file is deleted.

## GetTokenAccountsByOwnerJsonRpc.swift

Changed `TokenProgram.programId` → `PublicKey.tokenProgramId.base58`. The `base58` property on `PublicKey.tokenProgramId` encodes the same 32 bytes back to the same Base58 string. Functionally identical — correct.

## Code Quality

- Byte-packing uses `withUnsafeBytes(of:)` + `.littleEndian` — safe and idiomatic Swift
- All three files follow the caseless `enum` namespace pattern consistent with `SolanaSerializer`
- `Data()` initialized empty then appended to — no over-allocation, no off-by-one risk
- No force unwraps, no I/O, no side effects — pure instruction builders

## Build Status

`swift build` fails due to a **pre-existing** SPM dependency version mismatch (`HsToolKit` requires macOS 10.13 but `ObjectMapper` requires macOS 12.0). This is unrelated to the changes under review.

## Issues Found

None.

REVIEW_PASS
