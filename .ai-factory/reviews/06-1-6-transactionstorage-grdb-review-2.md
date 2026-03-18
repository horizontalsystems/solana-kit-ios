# Review 2: 1.6 TransactionStorage (GRDB)

**Files reviewed:**
- `Sources/SolanaKit/Core/Protocols.swift` (modified)
- `Sources/SolanaKit/Database/TransactionStorage.swift` (new, 488 lines)
- All referenced model files confirmed unchanged

**Build status:** BUILD SUCCEEDED (xcodebuild, iOS Simulator)

---

## Previous issues — all resolved

| # | Severity | Issue | Status |
|---|----------|-------|--------|
| 1 | CRITICAL | Missing `try` on `fetchOne` (line 165) | Fixed — `try` added (line 166) |
| 2 | CRITICAL | SQL injection via string interpolation of `address`/`mintAddress` | Fixed — all 7 occurrences now use `?` placeholders + `typeArgs` parameter |
| 3 | MEDIUM | Behavioral inconsistency: `fullTokenAccount`/`fullTokenAccounts` returned nil vs placeholder MintAccount | Fixed — now uses `?? MintAccount(address:, decimals: 0)` placeholder, consistent with `fetchTransactions` |
| 4 | MEDIUM | Unused JOIN in `fullTokenAccount`/`fullTokenAccounts` | Fixed — removed JOIN, uses simple separate queries |

---

## Current review

### Schema & migrations

- All 5 tables match their `Record` model definitions (column names, types, nullability). Verified each `Columns` enum against the DDL.
- DDL conflict policies match model `persistenceConflictPolicy` on all 5 tables.
- `tokenTransfers.transactionHash` FK with `ON DELETE CASCADE` is correct — GRDB enables `PRAGMA foreign_keys = ON` by default. When a `Transaction` is re-saved (INSERT OR REPLACE = DELETE + INSERT), the cascade deletes stale `TokenTransfer` rows.
- `from` and `to` (SQL reserved words) are properly quoted by GRDB's table builder in DDL. Raw SQL correctly uses `tx."from"` and `tx."to"`.

### Query builder correctness

- **Parameterized arguments order verified:** pagination args (`timestamp, timestamp, hash`) are appended first, then `typeArgs`. This matches the SQL clause order `WHERE (pagination) AND (type_condition)`. Correct for all combinations (both present, either alone, neither).
- **`LIMIT \(limit)`** — `limit` is `Int`, safe from injection. Consistent with EvmKit pattern.
- **`tt.incoming` bare in WHERE** — SQLite evaluates BOOLEAN columns as truthy/falsy. `tt.incoming` = true when 1, `NOT(tt.incoming)` = true when 0. Correct.
- **LEFT JOIN + NULL semantics** — when `incoming` filter is set, the LEFT JOIN means `tt.*` columns are NULL for transactions without token transfers. The OR structure `(SOL condition) OR (token transfer condition)` handles this correctly: SOL-only transactions match via the first clause, token transfers via the second.

### Protocol conformance

All 23 methods in `ITransactionStorage` are implemented in the extension. Signature match verified.

### CRUD methods

- Read methods use `try!` on `dbPool.read` (crash on DB error) — consistent with `MainStorage` and EvmKit pattern.
- Write methods propagate `throws` — consistent.
- `save(transactions:)` uses `save(db)` (INSERT OR REPLACE, triggers cascade) vs `updateTransactions` uses `update(db)` (UPDATE only, no cascade). Correct separation for different use cases.

---

## Minor observations (non-blocking)

1. **Non-atomic transaction + token transfer saves:** `save(transactions:)` and `save(tokenTransfers:)` are separate `dbPool.write` blocks. A crash between them leaves a transaction without its token transfers. Same pattern as Android. Future `TransactionSyncer` should call both in sequence; the next sync cycle recovers if interrupted.

2. **N+1 queries in `fetchTransactions`:** For each transaction, a separate query fetches token transfers, then one per transfer for mint accounts. Acceptable — mirrors Android's Room `@Relation` behavior and the result set is bounded by `LIMIT`.

3. **`tokenAccounts(mintAddresses:)` with empty array:** Generates `WHERE mintAddress IN ()` which returns no results. Correct but callers could short-circuit with an early return.

---

REVIEW_PASS
