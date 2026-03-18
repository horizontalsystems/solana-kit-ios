# Review: 1.5 MainStorage (GRDB) — Review 1

**Plan:** `.ai-factory/plans/05-1-5-mainstorage-grdb.md`
**Build:** PASS (`xcodebuild -scheme SolanaKit -destination 'generic/platform=iOS' build` — BUILD SUCCEEDED, 0 errors, 0 warnings)

## Files reviewed

| File | Status | Verdict |
|------|--------|---------|
| `Sources/SolanaKit/Core/Protocols.swift` | new | OK |
| `Sources/SolanaKit/Database/MainStorage.swift` | new | OK |
| `Sources/SolanaKit/Models/MintAccount.swift` | modified | OK |
| `Sources/SolanaKit/Models/TokenAccount.swift` | modified | OK |
| `Sources/SolanaKit/Models/TokenTransfer.swift` | modified | OK |
| `Sources/SolanaKit/Models/Transaction.swift` | modified | OK |

## New files

### Protocols.swift

Clean `IMainStorage` protocol with six methods. Uses `Int64` for lamports/height — matches `BalanceEntity.lamports` and `LastBlockHeightEntity.height` types exactly. No `address` parameter since the database is per-wallet (one file per walletId). Matches EvmKit's `IApiStorage` convention. No issues.

### MainStorage.swift

**Init pattern:** `DatabasePool` with `try!`, migrations with `try?` — matches EvmKit `ApiStorage` exactly.

**Migrations:** Single `"createMainTables"` migration creates all three singleton-row tables. Column names sourced from entity `Columns` enums. Primary keys use `onConflict: .replace` for the singleton-row pattern. Schema matches entity `encode(to:)` implementations. No issues.

**IMainStorage conformance:** Reads use `try! dbPool.read`, writes use `try dbPool.write` (propagating throws). This matches EvmKit's convention.

**`save()` vs `insert()` — minor deviation from EvmKit, functionally correct:** EvmKit's `ApiStorage` uses `entity.insert(db)` (relying on the table's `ON CONFLICT REPLACE`). This code uses `entity.save(db)` (which does update-if-exists, else insert). Both are correct. `save()` is arguably better: it avoids the delete-and-reinsert overhead that `ON CONFLICT REPLACE` triggers on `insert()` when a row already exists. The fetch-or-create + save pattern guarantees no conflict path is ever hit.

**Convenience init:** Creates `Application Support/solana-kit/` directory with `createDirectory(withIntermediateDirectories: true)` before calling the designated init. The `throws` covers the `FileManager` calls; the designated init's `try!` on `DatabasePool` is intentional (matches EvmKit — app should crash if it can't open its DB).

**`clear(walletId:)`:** Correctly deletes `.sqlite`, `.sqlite-wal`, `.sqlite-shm` files. Uses `fileExists` check before `removeItem` to avoid throwing on missing files. Note: if called while a `MainStorage` instance is still alive, the `DatabasePool` would have open file handles. This is acceptable — EvmKit has the same pattern, and `clear` is only called during wallet removal after `Kit` is deallocated.

## Modified files (MintAccount, TokenAccount, TokenTransfer, Transaction)

All changes are adding `public` to GRDB `Record` overrides (`databaseTableName`, `persistenceConflictPolicy`, `required init(row:)`, `encode(to:)`, `didInsert(_:)`). These are **necessary compilation fixes**: since the classes are `public`, Swift requires `required init` overrides to be at least as accessible as the class. The `encode(to:)` and `databaseTableName` changes are consistent best practice (matching superclass visibility). No behavioral change.

## Potential issues (non-critical)

None identified. The implementation is straightforward, follows established patterns, and compiles cleanly.

REVIEW_PASS
