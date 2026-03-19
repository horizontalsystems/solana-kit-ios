## Code Review — Round 2 (Post-Patch)

**Reviewing:** All changes from patch `13-3-3-jupiter-token-metadata-metaplex-nft-detection-patch-1.md`
**Files Changed:** 5 source files + 2 review/patch docs

### Changes Applied

| # | File | Change |
|---|------|--------|
| 1 | `Api/NftClient.swift` | Added `import HsExtensions`, changed `.chunked(into:)` to `.hs.chunked(into:)` |
| 2 | `Helper/Data+ReadLE.swift` (new) | Shared `internal` extension with `Data.readLE<T>(offset:)` |
| 3 | `Helper/SplMintLayout.swift` | Removed private `readLE` duplicate (now uses shared extension) |
| 4 | `Helper/MetaplexMetadataLayout.swift` | Removed private `readLE` duplicate; kept `readBorshString` in private extension |
| 5 | `Database/TransactionStorage.swift` | Changed `mintAccounts` DDL from `onConflict: .ignore` to `.replace` |

### Verification

**Fix 1 — NftClient chunked call:** Correct. `import HsExtensions` added at line 2, `.hs.chunked(into: chunkSize)` at line 54. The `HsExtensions.Swift` package is already a declared dependency in `Package.swift` (line 19, product name `HsExtensions` line 29). No additional dependency changes needed.

**Fix 2 — Shared readLE extension:** Correct. The new `Data+ReadLE.swift` declares `readLE` at `internal` access (default for `extension Data`). Both consumers work:
- `SplMintLayout.swift` calls `data.readLE(offset:)` directly — resolves to the internal extension. No `import` needed (same module).
- `MetaplexMetadataLayout.swift` line 198: `readBorshString` (in a `private extension Data`) calls `readLE(offset: cursor)`. A `private` extension member can call `internal` methods on the same type within the same module. Compiles correctly.

**Fix 3 — DDL conflict policy:** Correct. Line 88 now reads `onConflict: .replace`, matching `MintAccount.persistenceConflictPolicy`. The `addMintAccount` method (line 279–284) still uses explicit `insert(db, onConflict: .ignore)` — this is intentional and correctly preserved (prevents basic send-SPL pre-registration from overwriting enriched Metaplex data).

### No New Issues Introduced

- `Data.readLE` is `internal`, not `public` — it does not leak to library consumers.
- No migration needed for the DDL change: it only affects new database files, and GRDB's record-level `persistenceConflictPolicy` (`.replace`) already governs actual SQL for existing databases.
- No other files reference the removed private extensions.

REVIEW_PASS
