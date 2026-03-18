# Plan: 1.4 Token & Transaction Models

## Context

Define all data-layer types needed for SPL token accounts and transaction history — both GRDB `Record` entities for persistence and plain Swift composite types (`FullTransaction`, `FullTokenAccount`) for the public API surface. These models are consumed by `TransactionStorage` (milestone 1.6), managers (Phase 3), and the `Kit` facade (Phase 4).

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: GRDB Record Entities

- [x] **Task 1: MintAccount record**
  Files: `Sources/SolanaKit/Models/MintAccount.swift`
  Create a `class MintAccount: Record` following the same pattern as `BalanceEntity` (GRDB `Record` subclass, `Columns` enum with `ColumnExpression`, `init(row:)`, `encode(to:)`).
  Fields (from Android `MintAccount.kt`):
    - `address: String` — primary key (the mint address)
    - `decimals: Int`
    - `supply: Int64?` — nullable, not always fetched
    - `isNft: Bool` — defaults to `false`
    - `name: String?` — from metadata enrichment
    - `symbol: String?` — from metadata enrichment
    - `uri: String?` — from metadata enrichment
    - `collectionAddress: String?` — from metadata enrichment
  Table name: `"mintAccounts"`. Primary key on `address` with `onConflict: .ignore` (first write wins, matching Android's `IGNORE` strategy). Internal visibility (not `public`).

- [x] **Task 2: TokenAccount record**
  Files: `Sources/SolanaKit/Models/TokenAccount.swift`
  Create a `class TokenAccount: Record` following the same `BalanceEntity` pattern.
  Fields (from Android `TokenAccount.kt`):
    - `address: String` — primary key (the SPL token account / ATA address)
    - `mintAddress: String` — links to `MintAccount.address`
    - `balance: String` — stored as `String` to avoid floating-point precision loss (matches Android's `BigDecimal` stored as text via `RoomTypeConverters`). Provide a computed `var decimalBalance: Decimal` that converts via `Decimal(string:)`.
    - `decimals: Int`
  Table name: `"tokenAccounts"`. Primary key on `address` with `onConflict: .replace` (matching Android's `REPLACE` strategy). Internal visibility.

- [x] **Task 3: Transaction record**
  Files: `Sources/SolanaKit/Models/Transaction.swift`
  Create a `class Transaction: Record` following the same `BalanceEntity` pattern.
  Fields (from Android `Transaction.kt`):
    - `hash: String` — primary key (the transaction signature)
    - `timestamp: Int64` — Unix timestamp (seconds)
    - `fee: String?` — lamports as string (nullable, like Android's `BigDecimal?`)
    - `from: String?` — sender address (nullable for non-transfer txs)
    - `to: String?` — recipient address (nullable)
    - `amount: String?` — lamports as string (nullable)
    - `error: String?` — error message if the transaction failed
    - `pending: Bool` — defaults to `true`
    - `blockHash: String` — defaults to `""`, used for pending tx resend flow
    - `lastValidBlockHeight: Int64` — defaults to `0`, used for pending tx expiry check
    - `base64Encoded: String` — defaults to `""`, raw tx for re-broadcast
    - `retryCount: Int` — defaults to `0`
  Table name: `"transactions"`. Primary key on `hash` with `onConflict: .replace`. Provide computed `var decimalFee: Decimal?` and `var decimalAmount: Decimal?` for convenience. Internal visibility.

- [x] **Task 4: TokenTransfer record**
  Files: `Sources/SolanaKit/Models/TokenTransfer.swift`
  Create a `class TokenTransfer: Record` following the same pattern.
  Fields (from Android `TokenTransfer.kt`):
    - `id: Int64?` — auto-incremented primary key (nil on insert, GRDB assigns)
    - `transactionHash: String` — foreign key to `Transaction.hash`
    - `mintAddress: String` — the SPL token mint
    - `incoming: Bool` — direction flag
    - `amount: String` — stored as string for precision
  Table name: `"tokenTransfers"`. Auto-increment primary key on `id`. Add an index on `transactionHash` for efficient joins. Use `onConflict: .ignore` on insert (matching Android's `IGNORE` strategy). Provide a computed `var decimalAmount: Decimal`. Internal visibility.

- [x] **Task 5: LastSyncedTransaction record**
  Files: `Sources/SolanaKit/Models/LastSyncedTransaction.swift`
  Create a `class LastSyncedTransaction: Record` following the same pattern.
  Fields (from Android `LastSyncedTransaction.kt`):
    - `syncSourceName: String` — primary key (identifies which syncer this cursor belongs to)
    - `hash: String` — the last synced transaction signature (cursor for incremental sync)
  Table name: `"lastSyncedTransactions"`. Primary key on `syncSourceName` with `onConflict: .replace` (upsert on each sync, matching Android's `REPLACE` strategy). Internal visibility.

### Phase 2: Composite / DTO Types

- [x] **Task 6: FullTokenTransfer composite**
  Files: `Sources/SolanaKit/Models/FullTokenTransfer.swift`
  Create a plain Swift struct (not a `Record`, not persisted):
  ```swift
  struct FullTokenTransfer {
      let tokenTransfer: TokenTransfer
      let mintAccount: MintAccount
  }
  ```
  Internal visibility. This is assembled in memory by storage queries that join `TokenTransfer` + `MintAccount` on `mintAddress`. Matches Android's `FullTokenTransfer` data class.

- [x] **Task 7: FullTransaction composite**
  Files: `Sources/SolanaKit/Models/FullTransaction.swift`
  Create a plain Swift struct (not a `Record`):
  ```swift
  public struct FullTransaction {
      public let transaction: Transaction
      public let tokenTransfers: [FullTokenTransfer]
  }
  ```
  **Public** visibility — this is part of Kit's public API surface (exposed via `kit.transactionsPublisher` and `kit.transactions(fromHash:limit:)`). Assembled in memory from separate DB fetches of `Transaction` + `TokenTransfer` + `MintAccount`, matching Android's `FullTransaction` data class and the two-level nested `@Relation` pattern from `TransactionsDao`.

- [x] **Task 8: FullTokenAccount composite**
  Files: `Sources/SolanaKit/Models/FullTokenAccount.swift`
  Create a plain Swift struct (not a `Record`):
  ```swift
  public struct FullTokenAccount {
      public let tokenAccount: TokenAccount
      public let mintAccount: MintAccount
  }
  ```
  **Public** visibility — exposed via `kit.fungibleTokenAccountsPublisher` and `kit.fungibleTokenAccounts()`. Assembled in memory from `TokenAccount` + `MintAccount` joined on `mintAddress`. Matches Android's `FullTokenAccount` data class.

## Commit Plan
- **Commit 1** (after tasks 1-5): "Add GRDB record entities for token accounts, transactions, and sync cursors"
- **Commit 2** (after tasks 6-8): "Add composite DTO types for FullTransaction and FullTokenAccount"
