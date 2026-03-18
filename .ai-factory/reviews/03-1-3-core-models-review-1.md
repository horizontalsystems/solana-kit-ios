## Code Review Summary

**Files Reviewed:** 7 (Address.swift, SyncState.swift, RpcSource.swift, BalanceEntity.swift, LastBlockHeightEntity.swift, InitialSyncEntity.swift, PublicKey.swift)
**Risk Level:** 🟢 Low

### Context Gates

- **ARCHITECTURE.md** — `WARN`: The architecture doc's example `BalanceEntity` shows a `struct` with `FetchableRecord & PersistableRecord` conformance and stores balance as a `String` for precision. The actual implementation uses a `Record` subclass (which is `class`-based) and stores `lamports` as `Int64`. This is consistent with EvmKit's actual `AccountState.swift` (also a `Record` subclass), so the implementation follows the real EvmKit pattern correctly — the architecture doc example is slightly out of date with the actual code. No action needed.
- **RULES.md** — File does not exist. `WARN` (non-blocking).
- **ROADMAP.md** — Milestone 1.3 is present and marked `[x]` as completed. Aligned.

### Critical Issues

None found.

### Suggestions

None.

### Positive Notes

1. **Faithful EvmKit pattern adherence.** All three GRDB entities (`BalanceEntity`, `LastBlockHeightEntity`, `InitialSyncEntity`) follow EvmKit's `Record` subclass pattern exactly — singleton-row with a hardcoded primary key string, `Columns` enum, throwing `init(row:)`, and `encode(to:)`. The migration in `MainStorage` matches the column types and constraints precisely.

2. **Clean type flow through the stack.** The `IMainStorage` protocol uses `Int64` for both `balance()` and `lastBlockHeight()`, which maps cleanly to `BalanceEntity.lamports: Int64` and `LastBlockHeightEntity.height: Int64`. The lamports-to-SOL conversion (`Decimal(lamports) / 1_000_000_000`) is correctly done in `BalanceManager` (business logic layer), not in the entity itself — keeping the entity as a pure persistence type.

3. **Correct `SyncState` Equatable implementation.** The manual `Equatable` conformance uses `"\(lhsError)" == "\(rhsError)"` for the `.notSynced` case, which is the standard workaround for `Error` not conforming to `Equatable`. This matches EvmKit's exact pattern.

4. **Well-designed `Address` type.** Delegates all heavy lifting to `PublicKey` while adding `DatabaseValueConvertible` (blob storage) and `Codable` (Base58 string encoding) conformances correctly. The `Codable` implementation round-trips through `PublicKey`'s own `Codable`, ensuring consistent encoding.

5. **`RpcSource` is appropriately simple.** A plain struct with static factory methods in an extension — matches the EvmKit style. The `Network` raw values correctly use `"mainnet-beta"` (with hyphen), matching Solana's cluster naming convention.

6. **No layer violations.** All model types import only `Foundation` and `GRDB` — no imports of Core, Api, or Database layer types. The GRDB entities are `internal` (not `public`), while public value types (`Address`, `SyncState`, `RpcSource`) are correctly `public`.

REVIEW_PASS
