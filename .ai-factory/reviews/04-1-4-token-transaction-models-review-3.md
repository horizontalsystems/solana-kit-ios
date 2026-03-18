# Review: 1.4 Token & Transaction Models — Round 3

## Status of Previous Issues

| Round | ID | Issue | Status |
|-------|----|-------|--------|
| R1 | C1 | Public composite types expose internal Record classes | **Fixed** — all Record classes now `public class` |
| R1 | M1 | `from` SQL reserved keyword | Acknowledged — safe via GRDB `Columns` enum; migration note for 1.6 |
| R1 | M2 | CASCADE foreign key not in model | **Fixed** — migration note in `TokenTransfer.swift` doc comment |
| R2 | C1 | Stored properties on public classes are `internal` | **Fixed** — all properties now `public var` |

## Files Reviewed

| File | Type | Visibility |
|------|------|------------|
| `MintAccount.swift` | GRDB Record (8 stored props) | `public class`, `public var` properties |
| `TokenAccount.swift` | GRDB Record (4 stored + 1 computed) | `public class`, `public var` properties |
| `Transaction.swift` | GRDB Record (12 stored + 2 computed) | `public class`, `public var` properties |
| `TokenTransfer.swift` | GRDB Record (5 stored + 1 computed) | `public class`, `public var` properties |
| `LastSyncedTransaction.swift` | GRDB Record (2 stored) | `internal class` (correct) |
| `FullTokenTransfer.swift` | Plain struct | `public struct`, `public let` properties |
| `FullTransaction.swift` | Plain struct | `public struct`, `public let` properties |
| `FullTokenAccount.swift` | Plain struct | `public struct`, `public let` properties |

## Verification

### Access control
- Public Record classes (`MintAccount`, `TokenAccount`, `Transaction`, `TokenTransfer`): all stored and computed properties are `public var`. Convenience `init(...)` is internal (correct — external consumers receive these from Kit publishers, never construct them).
- `LastSyncedTransaction`: correctly internal — only used by `TransactionSyncer`.
- `FullTokenTransfer`, `FullTransaction`, `FullTokenAccount`: public structs with `public let` properties. Auto-synthesized init is internal (correct).

### Field fidelity against Android models
All fields verified against `solana-kit-android/` source:
- `MintAccount`: 8 fields — exact match
- `TokenAccount`: 4 fields — exact match
- `Transaction`: 12 fields — exact match (all default values match: `pending=true`, `blockHash=""`, `lastValidBlockHeight=0`, `base64Encoded=""`, `retryCount=0`)
- `TokenTransfer`: 5 fields — exact match (auto-increment `id`, foreign key `transactionHash`)
- `LastSyncedTransaction`: 2 fields — exact match
- `FullTransaction`, `FullTokenTransfer`, `FullTokenAccount`: composition structure matches Android `data class` definitions

### GRDB patterns
- All 5 Record entities follow established `BalanceEntity` pattern: `databaseTableName`, `Columns` enum with `ColumnExpression`, `init(row:)`, `encode(to:)`.
- `persistenceConflictPolicy` matches Android DAO strategies: IGNORE for `MintAccount`/`TokenTransfer`, REPLACE for `TokenAccount`/`Transaction`/`LastSyncedTransaction`.
- `TokenTransfer.didInsert(_:)` correctly captures auto-assigned `rowID`.

### Type mappings
- Kotlin `BigDecimal` → `String` storage + computed `Decimal` accessors (avoids floating-point precision loss)
- Kotlin `Long` → `Int64`, `Int` → `Int`, `Boolean` → `Bool`, nullable `?` → Swift `?`
- `Decimal(string:) ?? 0` provides safe fallback; `fee.flatMap { Decimal(string: $0) }` correctly propagates `nil`

### Runtime safety
- No migrations in this milestone (model definitions only; schema creation is 1.5/1.6)
- No race conditions — pure value/record types with no shared mutable state
- No type mismatches between `Columns` enum and `init(row:)`/`encode(to:)` — all columns round-trip correctly
- `from` reserved keyword: safe via GRDB `ColumnExpression` auto-quoting; migration note present for 1.6

## Critical Issues

None.

## Minor Issues

None new.

REVIEW_PASS
