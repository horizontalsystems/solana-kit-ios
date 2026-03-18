# Review: 1.4 Token & Transaction Models — Round 2

## Status of Round 1 Issues

| ID | Issue | Status |
|----|-------|--------|
| C1 | Public composite types expose internal Record classes | **Fixed** — `MintAccount`, `TokenAccount`, `Transaction`, `TokenTransfer` are now `public class`, `FullTokenTransfer` is now `public struct` with `public let` properties |
| M1 | `from` SQL reserved keyword | Acknowledged — GRDB auto-quotes via `Columns` enum; migration (1.6) should use `.name` pattern |
| M2 | CASCADE foreign key not captured in model | **Fixed** — migration note comment added to `TokenTransfer.swift` doc comment (lines 10-13) |

## Files Reviewed

All 8 model files read in full, compared against Android reference models (`solana-kit-android`) and EvmKit.Swift patterns.

## Critical Issues

### C1: Stored properties on public Record classes are `internal` — external consumers cannot read them

**Files:** `MintAccount.swift`, `TokenAccount.swift`, `Transaction.swift`, `TokenTransfer.swift`

All four public Record classes declare their stored properties without an access modifier, defaulting to `internal`:

```swift
// Transaction.swift
public class Transaction: Record {
    var hash: String          // internal — wallet app can't read this
    var timestamp: Int64      // internal
    var fee: String?          // internal
    // ... all 12 properties are internal
```

When the wallet app imports `SolanaKit` and receives a `FullTransaction` from `kit.transactionsPublisher`, it cannot access `transaction.hash`, `transaction.timestamp`, `mintAccount.name`, `tokenAccount.balance`, etc. — these are all invisible outside the module.

**Evidence:** EvmKit's `Transaction.swift` (the structural reference) declares every property as `public`:
```swift
// EvmKit.Swift/Sources/EvmKit/Models/Transaction.swift
public class Transaction: Record {
    public let hash: Data         // public
    public let timestamp: Int     // public
    public var isFailed: Bool     // public
    // ... all properties are public
```

Computed convenience properties (`decimalBalance`, `decimalFee`, `decimalAmount`) are also `internal` and need `public` access.

**Fix required for each file:**

`Transaction.swift` — 12 stored properties + 2 computed properties:
```swift
public var hash: String
public var timestamp: Int64
public var fee: String?
public var from: String?
public var to: String?
public var amount: String?
public var error: String?
public var pending: Bool
public var blockHash: String
public var lastValidBlockHeight: Int64
public var base64Encoded: String
public var retryCount: Int
public var decimalFee: Decimal? { ... }
public var decimalAmount: Decimal? { ... }
```

`MintAccount.swift` — 8 stored properties:
```swift
public var address: String
public var decimals: Int
public var supply: Int64?
public var isNft: Bool
public var name: String?
public var symbol: String?
public var uri: String?
public var collectionAddress: String?
```

`TokenAccount.swift` — 4 stored properties + 1 computed:
```swift
public var address: String
public var mintAddress: String
public var balance: String
public var decimals: Int
public var decimalBalance: Decimal { ... }
```

`TokenTransfer.swift` — 5 stored properties + 1 computed:
```swift
public var id: Int64?
public var transactionHash: String
public var mintAddress: String
public var incoming: Bool
public var amount: String
public var decimalAmount: Decimal { ... }
```

The convenience `init(...)` on each class can remain `internal` — external consumers receive these from Kit's publishers, they never construct them directly.

## Minor Issues

None new. Previous minor issues (M1, M2) have been addressed.

## Verification Checklist

- [x] All 5 Record entities follow `BalanceEntity` pattern (Record subclass, Columns enum, init(row:), encode(to:))
- [x] All fields match Android reference models exactly (verified against `solana-kit-android/` source)
- [x] `persistenceConflictPolicy` correctly maps Android DAO strategies: IGNORE for MintAccount/TokenTransfer, REPLACE for TokenAccount/Transaction/LastSyncedTransaction
- [x] `TokenTransfer.didInsert(_:)` correctly captures auto-assigned rowID
- [x] Decimal-as-String storage pattern consistent across all amount/fee fields
- [x] Composite types are plain structs with no GRDB conformance
- [x] Default values in `Transaction.init` match Android (`pending: true`, `blockHash: ""`, etc.)
- [x] `FullTokenTransfer` is now `public` with `public let` properties
- [x] `LastSyncedTransaction` correctly remains `internal`
- [x] Migration note for CASCADE foreign key added to `TokenTransfer` doc comment

## Verdict

One critical issue (C1: internal properties on public classes) must be fixed. The types are correctly declared `public` now, but their stored properties are still `internal`, making them useless to external consumers who receive them through Kit's Combine publishers.
