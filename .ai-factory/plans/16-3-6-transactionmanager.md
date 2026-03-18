# Plan: 3.6 TransactionManager

## Context

TransactionManager already exists with core functionality (handle/merge, notifyTransactionsUpdate, base PassthroughSubject publisher, and storage-delegating read queries). This milestone completes it by adding the **filtered reactive publishers** that let consumers subscribe to SOL-only, SPL-only, or direction-filtered transaction streams — mirroring Android's `allTransactionsFlow`, `solTransactionsFlow`, and `splTransactionsFlow`. The wallet address must be injected so the in-memory filter can compare `from`/`to` fields.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: TransactionManager — filtered publishers

- [x] **Task 1: Add `address` to TransactionManager and private filter helpers**
  Files: `Sources/SolanaKit/Transactions/TransactionManager.swift`
  Add a stored `address: String` property to `TransactionManager`, passed through `init(address:storage:)`. Implement two private helper methods mirroring Android `TransactionManager.kt` lines 115–129:
  - `hasSolTransfer(_:incoming:) -> Bool` — returns `true` when `transaction.decimalAmount` is non-nil and > 0, and if `incoming` is non-nil, checks that `transaction.to == address` (incoming) or `transaction.from == address` (outgoing). When `incoming` is `nil`, any tx with a non-nil amount qualifies.
  - `hasSplTransfer(mintAddress:tokenTransfers:incoming:) -> Bool` — returns `true` when any `FullTokenTransfer` has a matching `mintAccount.address`, and if `incoming` is non-nil, checks `tokenTransfer.incoming` matches. When `incoming` is `nil`, any transfer with the matching mint qualifies.

- [x] **Task 2: Add filtered Combine publishers to TransactionManager** (depends on Task 1)
  Files: `Sources/SolanaKit/Transactions/TransactionManager.swift`
  Add three public factory methods that return filtered `AnyPublisher<[FullTransaction], Never>` derived from the existing `transactionsSubject`. Each maps + filters the emitted batch, dropping empty results (`.filter { !$0.isEmpty }`). Follow the same derivation pattern as Android `_transactionsFlow.map { }.filter { it.isNotEmpty() }`:
  - `allTransactionsPublisher(incoming: Bool?) -> AnyPublisher<[FullTransaction], Never>` — when `incoming` is nil, pass through unchanged (but still filter empties); when non-nil, keep transactions where `hasSolTransfer` OR any `tokenTransfer.incoming` matches.
  - `solTransactionsPublisher(incoming: Bool?) -> AnyPublisher<[FullTransaction], Never>` — keep only transactions where `hasSolTransfer` returns true.
  - `splTransactionsPublisher(mintAddress: String, incoming: Bool?) -> AnyPublisher<[FullTransaction], Never>` — keep only transactions where `hasSplTransfer` returns true for the given mint.

### Phase 2: Kit.swift wiring

- [x] **Task 3: Update Kit.instance() to pass `address` into TransactionManager** (depends on Task 1)
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Change the `TransactionManager` instantiation in `Kit.instance()` from `TransactionManager(storage:)` to `TransactionManager(address: address, storage: transactionStorage)`.

- [x] **Task 4: Expose filtered transaction publishers on Kit** (depends on Task 2, Task 3)
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Add three public methods to `Kit` that delegate to `TransactionManager`'s new filtered publishers, next to the existing `transactionsPublisher` property:
  - `public func allTransactionsPublisher(incoming: Bool? = nil) -> AnyPublisher<[FullTransaction], Never>` — delegates to `transactionManager.allTransactionsPublisher(incoming:)`.
  - `public func solTransactionsPublisher(incoming: Bool? = nil) -> AnyPublisher<[FullTransaction], Never>` — delegates to `transactionManager.solTransactionsPublisher(incoming:)`.
  - `public func splTransactionsPublisher(mintAddress: String, incoming: Bool? = nil) -> AnyPublisher<[FullTransaction], Never>` — delegates to `transactionManager.splTransactionsPublisher(mintAddress:incoming:)`.
  These are factory methods (not stored publishers), following the EvmKit pattern where `transactionsPublisher(tagQueries:)` returns a new derived publisher per call.
