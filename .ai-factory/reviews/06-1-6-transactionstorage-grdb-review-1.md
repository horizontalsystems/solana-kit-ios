# Review: 1.6 TransactionStorage (GRDB)

**Files reviewed:**
- `Sources/SolanaKit/Core/Protocols.swift` (modified)
- `Sources/SolanaKit/Database/TransactionStorage.swift` (new)
- All referenced model files: `Transaction.swift`, `TokenTransfer.swift`, `TokenAccount.swift`, `MintAccount.swift`, `LastSyncedTransaction.swift`, `FullTransaction.swift`, `FullTokenAccount.swift`, `FullTokenTransfer.swift`

---

## CRITICAL

### 1. Compile error: missing `try` on `fetchOne` (TransactionStorage.swift:165)

`Transaction.filter(...).fetchOne(db)` is a throwing call but lacks `try` in the `if let` binding.

```swift
// Line 165 — BROKEN
if let fromHash = fromHash,
   let fromTx = Transaction.filter(Transaction.Columns.hash == fromHash).fetchOne(db) {
```

**Fix:** Add `try`:
```swift
if let fromHash = fromHash,
   let fromTx = try Transaction.filter(Transaction.Columns.hash == fromHash).fetchOne(db) {
```

This is a hard compile error — verified via `xcodebuild`.

### 2. SQL injection via string interpolation of `address` and `mintAddress`

Seven places in the complex query methods interpolate `self.address` or the `mintAddress` parameter directly into raw SQL strings:

| Line | Expression |
|------|-----------|
| 401 | `tx."to" = '\(address)'` |
| 404 | `tx."from" = '\(address)'` |
| 423 | `tx."to" = '\(address)'` |
| 425 | `tx."from" = '\(address)'` |
| 441 | `tt.mintAddress = '\(mintAddress)'` |
| 443 | `tt.mintAddress = '\(mintAddress)'` |
| 445 | `tt.mintAddress = '\(mintAddress)'` |

Solana addresses are base58-encoded (alphanumeric only) so exploitation risk is low in practice, but this violates the GRDB pattern used everywhere else in this file (parameterized `?` + `StatementArguments`). It also contradicts the `fetchTransactions` builder which correctly uses `?` for the pagination cursor.

**Fix:** Refactor `typeCondition` from a raw SQL string to a `(sql: String, args: [DatabaseValueConvertible])` tuple, or pass the address/mintAddress values through `StatementArguments` alongside the existing `args` array.

Example for `transactions(incoming:)`:
```swift
case .some(true):
    typeCondition = "((tx.amount IS NOT NULL AND tx.\"to\" = ?) OR tt.incoming)"
    typeArgs = [address]
```

Then in `fetchTransactions`, append `typeArgs` to `args` before executing.

---

## MEDIUM

### 3. Behavioral inconsistency: missing MintAccount handling

`fetchTransactions` (line 200-202) creates a **placeholder** `MintAccount(address: tt.mintAddress, decimals: 0)` when no mint is found:
```swift
mintAccount: mint ?? MintAccount(address: tt.mintAddress, decimals: 0)
```

But `fullTokenAccount` (line 348) and `fullTokenAccounts` (line 366) **return nil / drop entries** when no MintAccount is found:
```swift
guard let mintAcc = try MintAccount.fetchOne(db, key: tokenAcc.mintAddress) else {
    return nil
}
```

This means:
- `FullTokenTransfer` always succeeds (placeholder mint) — consistent with Android's `@Relation` which returns null-filled objects
- `FullTokenAccount` silently disappears when mint metadata hasn't been synced yet — inconsistent with Android's LEFT JOIN

**Fix:** Either create a placeholder `MintAccount` in `fullTokenAccount`/`fullTokenAccounts` (matching the `fetchTransactions` pattern), or make `FullTokenAccount.mintAccount` optional. The first option is simpler and consistent with existing code.

### 4. Unused JOIN in `fullTokenAccount` / `fullTokenAccounts`

Both methods execute a `LEFT JOIN` SQL query but then **discard the joined MintAccount data** and re-query it via `MintAccount.fetchOne(db, key:)`:

```swift
// Line 337-351: Does a JOIN, then ignores the ma.* columns and re-fetches
let sql = "SELECT ta.*, ma.* FROM tokenAccounts AS ta LEFT JOIN mintAccounts AS ma ..."
guard let row = try Row.fetchOne(db, sql: sql, ...) else { return nil }
let tokenAcc = try TokenAccount(row: row)
guard let mintAcc = try MintAccount.fetchOne(db, key: tokenAcc.mintAddress) else { // <-- redundant query
    return nil
}
```

This is wasteful but not incorrect. The JOIN becomes useful only if MintAccount is decoded from the same row (which requires GRDB column scoping via `AdaptedRowDecoder` or manual column offset, since `ta.*` and `ma.*` have overlapping column names like `address` and `decimals`).

**Fix (two options):**
- **Option A (simple):** Drop the JOIN entirely — just query `TokenAccount`, then `MintAccount` separately by key. Same number of queries, no confusion.
- **Option B (efficient):** Use GRDB associations (`TokenAccount.belongsTo(MintAccount)`) or manual row adapters to decode both from one row. More complex but single query per result.

Option A is recommended for now — matches the simplicity of the rest of the code.

---

## MINOR

### 5. `addTransactions` convenience method from plan not implemented

The plan's Task 3 described an `addTransactions(_ fullTransactions: [FullTransaction])` convenience method that wraps transaction + token transfer saves in one write block. This was omitted from both the protocol and implementation. Not a bug — but callers must be aware that `save(transactions:)` and `save(tokenTransfers:)` run in separate write blocks. A crash between them would leave a transaction without its token transfers (the cascade on `.replace` deletes old transfers, then the new ones aren't saved).

Consider adding a combined write method when `TransactionSyncer` is implemented (Phase 3).

### 6. `from` / `to` as SQL column names

These are SQL reserved words. GRDB's `TableDefinition.column()` quotes them automatically in the migration DDL, so the schema is correct. The raw SQL in query methods properly uses `tx."to"` and `tx."from"` with double-quotes. No action needed — just noting for future maintenance awareness.

---

## Positive observations

- Migration structure follows `MainStorage` pattern exactly — consistent
- Protocol grouping in `ITransactionStorage` is clean and well-organized
- `TokenTransfer` FK with `ON DELETE CASCADE` correctly handles transaction re-saves
- Auto-increment + `didInsert` pattern on `TokenTransfer` is correct
- `fullTransactions(hashes:)` correctly handles empty array early return
- Parameterized pagination cursor in `fetchTransactions` is correct
- `DISTINCT` in the main query correctly deduplicates when LEFT JOIN produces multiple rows

---

## Verdict

Two critical issues must be fixed before merge: the compile error (missing `try`) and the SQL injection via string interpolation. The behavioral inconsistency in MintAccount handling (medium) should also be addressed.

REVIEW_FAIL
