# Review: 1.4 Token & Transaction Models — Round 1

## Files Reviewed

- `Sources/SolanaKit/Models/MintAccount.swift`
- `Sources/SolanaKit/Models/TokenAccount.swift`
- `Sources/SolanaKit/Models/Transaction.swift`
- `Sources/SolanaKit/Models/TokenTransfer.swift`
- `Sources/SolanaKit/Models/LastSyncedTransaction.swift`
- `Sources/SolanaKit/Models/FullTokenTransfer.swift`
- `Sources/SolanaKit/Models/FullTransaction.swift`
- `Sources/SolanaKit/Models/FullTokenAccount.swift`

## Critical Issues

### C1: Access control mismatch — public composite types expose internal Record classes

**Files:** `FullTransaction.swift`, `FullTokenAccount.swift`, `FullTokenTransfer.swift`, `MintAccount.swift`, `TokenAccount.swift`, `Transaction.swift`, `TokenTransfer.swift`

`FullTransaction` and `FullTokenAccount` are declared `public` (correct — they are part of Kit's Combine API surface). However, the Record classes they expose as properties are declared `internal` (default):

```swift
// FullTransaction.swift
public struct FullTransaction {
    public let transaction: Transaction       // Transaction is internal
    public let tokenTransfers: [FullTokenTransfer]  // FullTokenTransfer is internal
}

// FullTokenAccount.swift
public struct FullTokenAccount {
    public let tokenAccount: TokenAccount     // TokenAccount is internal
    public let mintAccount: MintAccount       // MintAccount is internal
}
```

Swift enforces access control at the declaration site. A `public` property whose type is `internal` is a compile error:
```
error: property cannot be declared public because its type uses an internal type
```

This is currently masked because the build fails earlier on dependency platform version mismatches, but will surface once those are resolved.

**Evidence:** EvmKit declares `public class Transaction: Record` and `public class FullTransaction` — all model types exposed through the public API are public.

**Fix required:** Make the following types `public`:
- `MintAccount` → `public class MintAccount: Record`
- `TokenAccount` → `public class TokenAccount: Record`
- `Transaction` → `public class Transaction: Record`
- `TokenTransfer` → `public class TokenTransfer: Record`
- `FullTokenTransfer` → `public struct FullTokenTransfer` with `public let` properties

`LastSyncedTransaction` can remain `internal` — it is only used by `TransactionSyncer` internally.

When making Record classes public, their stored properties should also be reviewed for access level. Currently all properties are `var` (internal), which is fine for internal mutation by storage/managers. The public composite types (`FullTransaction`, `FullTokenAccount`) mediate external access.

## Minor Issues

### M1: `from` is a SQL reserved keyword in Transaction

**File:** `Transaction.swift:89`

The column name `from` (in `Transaction.Columns.from`) is a SQL reserved keyword. GRDB's query builder auto-quotes column names when using the `Columns` enum, so filter/order expressions are safe. However, if raw SQL is used in migrations (milestone 1.6), the column must be explicitly quoted:

```sql
-- Must use double-quotes in raw SQL
t.column("\"from\"", .text)
-- Or better: use the Columns enum name
t.column(Transaction.Columns.from.name, .text)
```

The second form (using `.name`) is what EvmKit uses and is safe — GRDB handles quoting. Not a bug in the model itself, but worth noting for the migration implementor.

### M2: Foreign key + CASCADE delete not captured in model

**File:** `TokenTransfer.swift`

Android's `TokenTransfer` defines a foreign key to `Transaction.hash` with `onDelete = CASCADE`:
```kotlin
foreignKeys = [ForeignKey(entity = Transaction::class, ..., onDelete = CASCADE)]
```

The Swift model can't express this (it's a migration concern), but the TransactionStorage migration (milestone 1.6) must create this foreign key. Consider adding a code comment to `TokenTransfer.swift` noting this dependency for the migration implementor.

## Verification

- All 5 Record entities follow the established `BalanceEntity` pattern: `class Foo: Record`, `Columns` enum, `init(row:)`, `encode(to:)`.
- All fields match the Android reference models exactly (verified against `solana-kit-android/` source).
- `persistenceConflictPolicy` overrides correctly map Android's `OnConflictStrategy`: IGNORE for `MintAccount`/`TokenTransfer`, REPLACE for `TokenAccount`/`Transaction`/`LastSyncedTransaction`.
- `TokenTransfer.didInsert(_:)` correctly captures the auto-assigned rowID.
- Decimal-as-String storage pattern is consistent across `TokenAccount.balance`, `Transaction.fee/amount`, `TokenTransfer.amount`.
- Composite types (`FullTransaction`, `FullTokenAccount`, `FullTokenTransfer`) are plain structs with no GRDB conformance — correct per EvmKit pattern.
- Default values in `Transaction.init` match Android exactly (`pending: true`, `blockHash: ""`, etc.).

## Verdict

One critical issue (C1: access control) must be fixed before proceeding. The models are otherwise correct and faithful to the Android reference.
