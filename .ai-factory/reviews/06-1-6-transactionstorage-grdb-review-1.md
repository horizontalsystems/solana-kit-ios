## Code Review Summary

**Files Reviewed:** 2 (`Sources/SolanaKit/Database/TransactionStorage.swift`, `Sources/SolanaKit/Core/Protocols.swift`)
**Risk Level:** 🟢 Low

### Context Gates

- **ARCHITECTURE.md:** WARN — The `ITransactionStorage` protocol shown in ARCHITECTURE.md is a simplified sketch (5 methods) that diverges from the actual implementation (22 methods). The doc is aspirational; the real protocol is correct and complete. Consider updating ARCHITECTURE.md to reflect the actual protocol surface, or noting it as illustrative-only.
- **RULES.md:** WARN — File does not exist. No project-specific hard constraints to check against.
- **ROADMAP.md:** OK — Milestone 1.6 is listed under Phase 1 and marked `[x]`.

### Critical Issues

None.

### Suggestions

1. **MintAccount DDL vs Record conflict policy mismatch** (`TransactionStorage.swift` line 88)
   The migration creates the `mintAccounts` table with `onConflict: .ignore` on the primary key, but `MintAccount`'s Record class declares `persistenceConflictPolicy` as `insert: .replace, update: .replace`. When GRDB's Record methods (`save`, `insert`, `update`) are used, the **class-level policy always wins** — GRDB emits `INSERT OR REPLACE` regardless of the DDL constraint. The DDL's `.ignore` is effectively dead code that only applies to raw SQL `INSERT` statements without an explicit conflict clause.

   This is not a runtime bug (the Record policy is deterministic), but the mismatch is confusing to future readers. Consider either:
   - Changing the DDL to `onConflict: .replace` to match the class, or
   - Adding a comment in the migration explaining the intentional divergence (the DDL `.ignore` serves as a safety net for hypothetical raw-SQL inserts)

2. **N+1 query pattern in `fullTokenAccounts()`** (`TransactionStorage.swift` lines 351-360)
   For each `TokenAccount`, a separate `MintAccount.filter(...).fetchOne(db)` query runs. With N token accounts this is N+1 queries total. The plan (Task 4) suggested a single SQL JOIN. For typical wallets (<100 SPL tokens) this is fine, but a single `LEFT JOIN` would be more efficient and is easy to implement:
   ```sql
   SELECT ta.*, ma.* FROM tokenAccounts AS ta
   LEFT JOIN mintAccounts AS ma ON ta.mintAddress = ma.address
   ```
   The same N+1 pattern exists in `fullTokenAccount(mintAddress:)` (2 queries) and in the `fetchTransactions` helper (N queries per transaction for token transfers, then N per transfer for mints). The `fetchTransactions` case is harder to optimize due to the nested structure, but `fullTokenAccounts()` is a straightforward JOIN candidate.

3. **`LIMIT` uses string interpolation instead of parameter** (`TransactionStorage.swift` line 186)
   `sql += " LIMIT \(limit)"` is safe because `limit` is an `Int`, but for consistency with the rest of the parameterized query (which uses `?` placeholders and `StatementArguments`), consider appending `" LIMIT ?"` and adding `limit` to the `args` array. This is purely a style/consistency point.

### Positive Notes

- **Parameterized queries for user-controlled values** — wallet `address` and `mintAddress` values always use `?` placeholders and `StatementArguments`, preventing SQL injection. Good.
- **Correct keyset pagination** — The `(timestamp < ? OR (timestamp = ? AND hash < ?))` condition correctly implements seek pagination for `ORDER BY timestamp DESC, hash DESC`.
- **`DISTINCT` in JOIN queries** — Prevents duplicate `Transaction` rows when a transaction has multiple token transfers in the LEFT JOIN result.
- **Empty-array guard in `fullTransactions(hashes:)`** — Avoids generating invalid SQL (`IN ()`) for the empty case.
- **`addMintAccount` uses explicit `.ignore`** — Correctly prevents overwriting enriched Metaplex metadata with basic records during SPL send pre-registration.
- **Protocol conformance is clean** — All 22 `ITransactionStorage` protocol methods match their implementations exactly. The protocol/implementation split follows the same pattern as `IMainStorage`/`MainStorage`.
- **Consistent `try!`/`throws` convention** — Reads use `try!` (crash on DB corruption), writes propagate `throws` — consistent with MainStorage and the EvmKit pattern.
- **SQL reserved word handling** — `from` and `to` columns are properly double-quoted (`\"from\"`, `\"to\"`) in raw SQL queries.

REVIEW_PASS
