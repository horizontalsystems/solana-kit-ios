# Review: 3.6 TransactionManager

## Files Reviewed
- `Sources/SolanaKit/Transactions/TransactionManager.swift` — new `address` property, filter helpers, filtered publishers
- `Sources/SolanaKit/Core/Kit.swift` — factory wiring update, three new public methods

## Build
- `xcodebuild` iOS Simulator build: **SUCCEEDED**

## Correctness

### Filter helpers — correct
- `hasSolTransfer(_:incoming:)` correctly mirrors Android lines 115–122. Checks `decimalAmount` non-nil + > 0, then direction.
- `hasSplTransfer(mintAddress:tokenTransfers:incoming:)` correctly mirrors Android lines 124–129. Uses `contains(where:)` with mint match + optional direction.
- Property accesses verified against model types: `Transaction.decimalAmount` (Decimal?), `Transaction.to` (String?), `Transaction.from` (String?), `TokenTransfer.incoming` (Bool), `MintAccount.address` (String) — all exist and have correct types.

### Filtered publishers — correct
- `allTransactionsPublisher(incoming:)` matches Android's `allTransactionsFlow(incoming:)`: nil incoming passes all through; non-nil keeps txs with matching SOL transfer OR any matching token transfer direction.
- `solTransactionsPublisher(incoming:)` matches Android's `solTransactionsFlow(incoming:)`.
- `splTransactionsPublisher(mintAddress:incoming:)` matches Android's `splTransactionsFlow(mintAddress:incoming:)`.
- All three correctly apply `.filter { !$0.isEmpty }` to suppress empty batches (mirrors Kotlin `.filter { it.isNotEmpty() }`).
- `incoming` and `mintAddress` are value types captured by value in closures — correct, no stale-reference risk.

### Kit wiring — correct
- `TransactionManager(address: address, storage: transactionStorage)` — address passed correctly.
- Three public methods on Kit delegate directly to TransactionManager — no extra logic, clean pass-through.

### Thread safety — OK
- `address` is `let` (immutable) — safe.
- Filter helpers are pure functions with no side effects.
- `transactionsSubject.send()` is always dispatched to main queue (verified in `handle()` line 193 and `notifyTransactionsUpdate()` line 207). Combine's `.map` and `.filter` operators execute synchronously on the sending thread, so filtered publishers deliver on main.
- `[weak self]` captures prevent retain cycles through the Combine pipeline.

### Dual-subject architecture — acceptable
Kit has its own `transactionsSubject` (relay fed by `ISyncManagerDelegate.didUpdate(transactions:)`) while the filtered publishers derive from TransactionManager's `transactionsSubject` (the source). Data flows: TM.subject → SyncManager sink → Kit.didUpdate → Kit.subject (one main-queue hop later). This means `Kit.transactionsPublisher` fires one main-queue tick after the filtered publishers. Not a bug — consumers use one or the other, not both — but worth knowing. Matches the Android pattern where SolanaKit only exposes the filtered flows (no raw relay).

## Minor Notes (non-blocking)

1. **`hasSolTransfer` with zero-amount edge case**: Android returns `true` for `amount = 0` (non-null) when `incoming = nil` (the `amount > 0` check only runs in the direction-filtered branch). iOS returns `false` because the guard combines both checks. This is an improvement — zero-amount transactions aren't meaningful SOL transfers — but is a minor behavioral deviation from Android. No action needed.

## Verdict
No bugs, no security issues, no runtime risks. Implementation faithfully ports Android's filtered flow pattern to Combine with correct thread safety and memory management.

REVIEW_PASS
