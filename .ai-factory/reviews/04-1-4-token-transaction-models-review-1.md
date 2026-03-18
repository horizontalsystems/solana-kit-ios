## Code Review Summary

**Files Reviewed:** 8
**Risk Level:** Low

### Files

| File | Type | Visibility |
|------|------|------------|
| `Sources/SolanaKit/Models/MintAccount.swift` | GRDB Record (8 stored props) | `public class`, `public var` properties |
| `Sources/SolanaKit/Models/TokenAccount.swift` | GRDB Record (4 stored + 1 computed) | `public class`, `public var` properties |
| `Sources/SolanaKit/Models/Transaction.swift` | GRDB Record (12 stored + 2 computed) | `public class`, `public var` properties |
| `Sources/SolanaKit/Models/TokenTransfer.swift` | GRDB Record (5 stored + 1 computed) | `public class`, `public var` properties |
| `Sources/SolanaKit/Models/LastSyncedTransaction.swift` | GRDB Record (2 stored) | `internal class` (correct) |
| `Sources/SolanaKit/Models/FullTokenTransfer.swift` | Plain struct | `public struct`, `public let` properties |
| `Sources/SolanaKit/Models/FullTransaction.swift` | Plain struct | `public struct`, `public let` properties |
| `Sources/SolanaKit/Models/FullTokenAccount.swift` | Plain struct | `public struct`, `public let` properties |

### Context Gates

- **ARCHITECTURE.md**: WARN — Architecture doc's GRDB entity example shows `struct ... Codable, FetchableRecord, PersistableRecord` pattern, but actual implementation uses `class ... Record` subclassing (consistent with EvmKit and all other entities in this project). Not a real issue — the doc example is illustrative, the actual pattern is correct and consistent.
- **RULES.md**: Not present (no file). WARN — no blocking rules to check.
- **ROADMAP.md**: Milestone 1.4 is correctly marked `[x]`. All 8 model types listed in the milestone description are implemented. No alignment issues.

### Critical Issues

None.

### Suggestions

None.

### Positive Notes

- **Field fidelity**: All fields verified against Android reference models (`solana-kit-android/solanakit/src/main/java/.../models/`). Every field name, type, nullability, and default value matches the Android counterpart exactly (with appropriate Kotlin-to-Swift translations: `BigDecimal` -> `String` storage, `Long` -> `Int64`, `Boolean` -> `Bool`).

- **Access control is correct**: All four public Record classes (`MintAccount`, `TokenAccount`, `Transaction`, `TokenTransfer`) have `public var` stored properties and `public` computed Decimal accessors. `LastSyncedTransaction` is correctly `internal` since it's only used by `TransactionSyncer`. The `init(...)` constructors are `internal` (correct — external consumers receive these from Kit's publishers, never construct them). The `Columns` enums are `internal` (correct — consumers use Kit's API, not direct GRDB queries).

- **GRDB Record pattern is consistent**: All 5 Record entities follow the established `BalanceEntity` pattern: `databaseTableName`, `Columns` enum with `ColumnExpression`, `required init(row:)`, `encode(to:)`, `persistenceConflictPolicy`. Override methods are properly marked `public override`.

- **Conflict policies align with Android DAO strategies**: `MintAccount` uses `.replace` for normal save (Metaplex enrichment overwrites basic records) with explicit `.ignore` in `addMintAccount()` for pre-registration. `TokenTransfer` uses `.ignore` (first-write-wins). `TokenAccount`/`Transaction`/`LastSyncedTransaction` use `.replace` (upsert). All match the Android `@Insert(onConflict = ...)` annotations.

- **Composite types are clean**: `FullTransaction`, `FullTokenAccount`, `FullTokenTransfer` are plain Swift structs with no GRDB conformance. Their synthesized memberwise inits are `internal` (correct — only internal code constructs them, external consumers receive them). The public `let` properties ensure immutability for consumers.

- **Decimal-as-String storage pattern is sound**: `TokenAccount.balance`, `Transaction.fee`, `Transaction.amount`, `TokenTransfer.amount` all store as `String` to avoid floating-point precision loss (matching Android's `BigDecimal` via Room type converters). Computed `Decimal` accessors use `Decimal(string:) ?? 0` for non-nullable fields and `flatMap { Decimal(string: $0) }` for nullable fields — safe fallbacks in both cases.

- **`TokenTransfer.didInsert(_:)`** correctly captures the auto-assigned `rowID` after insert, matching the GRDB auto-increment pattern.

- **Documentation quality**: Every file has comprehensive doc comments explaining purpose, Android reference, conflict strategy rationale, and migration notes (e.g., the CASCADE foreign key note in `TokenTransfer`).

REVIEW_PASS
