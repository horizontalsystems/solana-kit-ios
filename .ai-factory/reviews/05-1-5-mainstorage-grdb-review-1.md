## Code Review Summary

**Files Reviewed:** 4 (`Protocols.swift`, `MainStorage.swift`, `BalanceEntity.swift`, `LastBlockHeightEntity.swift`, `InitialSyncEntity.swift`)
**Risk Level:** 🟢 Low

### Context Gates

- **ARCHITECTURE.md:** WARN — The `IMainStorage` protocol in `ARCHITECTURE.md` shows different signatures (`balance(address:) -> Decimal?`, `lastBlockHeight() -> Int?`, address parameters on several methods). The actual implementation uses `Int64` for lamports/height with no address parameter (per-wallet database makes it implicit). These are deliberate improvements over the blueprint. The architecture doc also shows `DatabaseQueue`; the code uses `DatabasePool` (matching EvmKit's actual implementation). The architecture document should be updated to reflect reality, but this is non-blocking.
- **RULES.md:** No file present — WARN (non-blocking).
- **ROADMAP.md:** Milestone 1.5 is marked `[x]` completed. Aligns with implemented code.

### Critical Issues

None.

### Suggestions

1. **Unnecessary fetch-then-save in `save(balance:)` and `save(lastBlockHeight:)`** (`MainStorage.swift` lines 112-118, 126-132)

   Both methods fetch the existing entity before mutating and saving:
   ```swift
   let entity = try BalanceEntity.fetchOne(db) ?? BalanceEntity(lamports: 0)
   entity.lamports = balance
   try entity.save(db)
   ```
   Since the tables use `onConflict: .replace` on the primary key, a direct create-and-save (like `setInitialSynced()` already does on line 141-143) would be equivalent and skip the extra SELECT:
   ```swift
   func save(balance: Int64) throws {
       try dbPool.write { db in
           let entity = BalanceEntity(lamports: balance)
           try entity.save(db)
       }
   }
   ```
   This is consistent with `setInitialSynced()` which already uses the simpler pattern. Not a bug — the fetch-or-create approach is correct — but the extra read is unnecessary overhead.

2. **ARCHITECTURE.md drift** — The `IMainStorage` protocol blueprint in `ARCHITECTURE.md` no longer matches the implementation. The doc shows `Decimal` types with `address` parameters; the code correctly uses `Int64` (lamports) with no address (per-wallet DB). Consider updating the architecture doc to stay in sync and avoid confusion for future contributors.

### Positive Notes

- Clean separation: `IMainStorage` protocol in `Protocols.swift`, implementation in `MainStorage.swift` extension — follows EvmKit's convention exactly.
- Singleton-row pattern with fixed `primaryKey` constant and `onConflict: .replace` is correctly implemented across all three entity types.
- The `clear(walletId:)` static method correctly removes all three SQLite companion files (`.sqlite`, `.sqlite-wal`, `.sqlite-shm`).
- Convenience init encapsulates the `Application Support/solana-kit/` directory path, matching the plan and the wallet's per-database-per-wallet pattern.
- `try!` for reads / `throws` for writes is a reasonable evolution from EvmKit's `try!` reads / `try?` writes — propagating write errors is safer than silently swallowing them.
- All three entity `Record` subclasses correctly handle the singleton-row pattern: `private let primaryKey` with static default, proper `encode(to:)`, and `init(row:)` that doesn't need to read the primary key column.
- Migration groups all three tables in a single `"createMainTables"` migration — clean, since there are no prior versions to worry about.

REVIEW_PASS
