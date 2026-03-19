## Code Review Summary

**Files Reviewed:** 5
**Risk Level:** 🟢 Low

### Context Gates

- **ARCHITECTURE.md** — WARN: The three new files live in `Sources/SolanaKit/Programs/`, which is not listed in the architecture folder structure (only `Core/`, `Api/`, `Transactions/`, `Database/`, `Models/` are documented). However, the `Programs/` directory is a pure-function instruction builder layer with zero upward dependencies — it sits at the same conceptual level as `Models/` (pure value types, imported by all layers) and does not violate any dependency rules. The `Helper/` directory (containing `SolanaSerializer.swift`) follows the same pattern of being undocumented in ARCHITECTURE.md but structurally sound. This is a documentation gap, not an architectural violation.
- **RULES.md** — file does not exist. WARN (non-blocking).
- **ROADMAP.md** — Milestone 4.4 is correctly marked `[x]` (complete). Description matches what was implemented.

### Critical Issues

None.

### Suggestions

None.

### Positive Notes

- **Correct Solana binary specifications.** All instruction discriminators, data layouts, and account meta orderings match the official Solana program specifications:
  - `SystemProgram.transfer`: `UInt32(2)` discriminator (4 bytes) + `UInt64` lamports (8 bytes) = 12 bytes. Correct.
  - `TokenProgram.transfer`: `UInt8(3)` discriminator + `UInt64` amount = 9 bytes. Correct.
  - `TokenProgram.transferChecked`: `UInt8(12)` discriminator + `UInt64` amount + `UInt8` decimals = 10 bytes. Correct.
  - `AssociatedTokenAccountProgram.createIdempotent`: `Data([1])` discriminator with 7 account metas in the correct order. Correct.
  - The 4-byte vs 1-byte discriminator width difference between SystemProgram and TokenProgram is correct per the Solana specification.

- **Safe byte-packing pattern.** Uses `withUnsafeBytes(of: value.littleEndian)` consistently — no force unwraps, no I/O, no side effects. All three files produce deterministic `Data` output.

- **Clean deletion of `Models/TokenProgram.swift`.** The old file only held a redundant `programId` string constant. The single reference in `GetTokenAccountsByOwnerJsonRpc.swift` was correctly updated to `PublicKey.tokenProgramId.base58`. Grep confirms zero remaining references to the old `TokenProgram.programId`.

- **Consistent namespace pattern.** All three types use caseless `enum` namespaces, matching the existing `SolanaSerializer` and later `ComputeBudgetProgram` patterns.

- **`TransactionInstruction` compatibility verified.** The `programId`/`keys`/`data` struct matches exactly what `SolanaSerializer.compile()` consumes — no type mismatches or missing fields.

- **ATA PDA derivation is correct.** Seeds `[wallet.data, tokenProgramId.data, mint.data]` with `associatedTokenProgramId` match the Solana ATA specification and the Android implementation.

- **Downstream callers are correct.** `TransactionManager.sendSol()` and `sendSpl()` use the new builders with proper argument ordering and types.

REVIEW_PASS
