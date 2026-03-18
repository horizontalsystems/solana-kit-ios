# Plan: 1.6 TransactionStorage (GRDB)

## Context

Create the second GRDB database (`TransactionStorage`) that persists transactions, SPL token transfers, token accounts, mint accounts, and syncer cursor state. This is the storage backbone for transaction history, token portfolio, and incremental sync — all five entity models already exist as `Record` subclasses.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Protocol & Schema

- [x] **Task 1: Define ITransactionStorage protocol**
  Files: `Sources/SolanaKit/Core/Protocols.swift`
  Add `ITransactionStorage` protocol below the existing `IMainStorage`. Include all method signatures that `TransactionStorage` will implement. Group methods by domain:
  - **Transaction CRUD:** `save(transactions:)`, `transaction(hash:) -> Transaction?`, `pendingTransactions() -> [Transaction]`, `lastNonPendingTransaction() -> Transaction?`, `updateTransactions(_:)`
  - **TokenTransfer:** `save(tokenTransfers:)`
  - **MintAccount:** `save(mintAccounts:)`, `mintAccount(address:) -> MintAccount?`, `addMintAccount(_:)`
  - **TokenAccount:** `save(tokenAccounts:)`, `tokenAccount(mintAddress:) -> TokenAccount?`, `allTokenAccounts() -> [TokenAccount]`, `tokenAccounts(mintAddresses:) -> [TokenAccount]`, `tokenAccountExists(mintAddress:) -> Bool`, `addTokenAccount(_:)`, `fullTokenAccount(mintAddress:) -> FullTokenAccount?`, `fullTokenAccounts() -> [FullTokenAccount]`
  - **Syncer state:** `lastSyncedTransaction(syncSourceName:) -> LastSyncedTransaction?`, `save(lastSyncedTransaction:)`
  - **Complex queries:** `transactions(incoming:fromHash:limit:) -> [FullTransaction]`, `solTransactions(incoming:fromHash:limit:) -> [FullTransaction]`, `splTransactions(mintAddress:incoming:fromHash:limit:) -> [FullTransaction]`, `fullTransactions(hashes:) -> [FullTransaction]`
  All read methods return non-optional arrays or optional singles. All write methods `throws`. Follow `IMainStorage` conventions: reads use `try!` internally, writes propagate `throws`.

- [x] **Task 2: Create TransactionStorage scaffold with migrations** (depends on Task 1)
  Files: `Sources/SolanaKit/Database/TransactionStorage.swift`
  Create `final class TransactionStorage` following `MainStorage`'s exact structure:
  - `private let dbPool: DatabasePool`
  - Designated `init(databaseDirectoryUrl:databaseFileName:)` — opens `DatabasePool` with `try!`, runs `try? migrator.migrate(dbPool)`
  - Convenience `init(walletId:)` — builds path `Application Support/solana-kit/transactions-<walletId>.sqlite`, creates directory if needed
  - `private var migrator: DatabaseMigrator` computed property with one migration `"createTransactionTables"` that creates all five tables:

  **`transactions`** — columns from `Transaction.Columns`: `hash` TEXT NOT NULL, `timestamp` INTEGER NOT NULL, `fee` TEXT, `from` TEXT, `to` TEXT, `amount` TEXT, `error` TEXT, `pending` BOOLEAN NOT NULL, `blockHash` TEXT NOT NULL, `lastValidBlockHeight` INTEGER NOT NULL, `base64Encoded` TEXT NOT NULL, `retryCount` INTEGER NOT NULL. Primary key: `[hash]` with `onConflict: .replace`.

  **`tokenTransfers`** — `t.autoIncrementedPrimaryKey(Columns.id.name)`, `transactionHash` TEXT NOT NULL with `.references("transactions", onDelete: .cascade)`, `mintAddress` TEXT NOT NULL, `incoming` BOOLEAN NOT NULL, `amount` TEXT NOT NULL. Add index on `transactionHash` column via `t.column(...).indexed()`.

  **`tokenAccounts`** — `address` TEXT NOT NULL, `mintAddress` TEXT NOT NULL, `balance` TEXT NOT NULL, `decimals` INTEGER NOT NULL. Primary key: `[address]` with `onConflict: .replace`.

  **`mintAccounts`** — `address` TEXT NOT NULL, `decimals` INTEGER NOT NULL, `supply` INTEGER, `isNft` BOOLEAN NOT NULL, `name` TEXT, `symbol` TEXT, `uri` TEXT, `collectionAddress` TEXT. Primary key: `[address]` with `onConflict: .ignore`.

  **`lastSyncedTransactions`** — `syncSourceName` TEXT NOT NULL, `hash` TEXT NOT NULL. Primary key: `[syncSourceName]` with `onConflict: .replace`.

  Also add `static func clear(walletId:)` that removes `.sqlite`, `.sqlite-wal`, `.sqlite-shm` for `transactions-<walletId>` — same pattern as `MainStorage.clear`.

### Phase 2: Simple CRUD Methods

- [x] **Task 3: Implement transaction and token transfer CRUD** (depends on Task 2)
  Files: `Sources/SolanaKit/Database/TransactionStorage.swift`
  Add methods to `TransactionStorage` (not yet in the `ITransactionStorage` extension — wire protocol conformance in Task 6):
  - `save(transactions:)` — `dbPool.write`, loop `try transaction.save(db)`. Throws.
  - `save(tokenTransfers:)` — `dbPool.write`, loop `try tokenTransfer.save(db)`. Throws.
  - `transaction(hash:) -> Transaction?` — `dbPool.read`, `Transaction.filter(Columns.hash == hash).fetchOne(db)`. Uses `try!`.
  - `pendingTransactions() -> [Transaction]` — `dbPool.read`, `Transaction.filter(Columns.pending == true).order(Columns.timestamp).fetchAll(db)`. Uses `try!`.
  - `lastNonPendingTransaction() -> Transaction?` — `dbPool.read`, `Transaction.filter(Columns.pending == false).order(Columns.timestamp.desc).fetchOne(db)`. Uses `try!`.
  - `updateTransactions(_ transactions:)` — `dbPool.write`, loop `try transaction.update(db)`. Throws.
  - `addTransactions(_ fullTransactions: [FullTransaction])` — convenience that calls `save(transactions:)` for the `Transaction` objects and `save(tokenTransfers:)` for all nested `TokenTransfer` objects extracted from `FullTokenTransfer` arrays. Throws.

- [x] **Task 4: Implement mint account and token account CRUD** (depends on Task 2)
  Files: `Sources/SolanaKit/Database/TransactionStorage.swift`
  Add methods:
  - `save(mintAccounts:)` — `dbPool.write`, loop `try mintAccount.save(db)`. Throws.
  - `addMintAccount(_:)` — `dbPool.write`, single `try mintAccount.save(db)`. Throws.
  - `mintAccount(address:) -> MintAccount?` — `dbPool.read`, filter by address. Uses `try!`.
  - `save(tokenAccounts:)` — `dbPool.write`, loop. Throws.
  - `addTokenAccount(_:)` — `dbPool.write`, single save. Throws.
  - `tokenAccount(mintAddress:) -> TokenAccount?` — `dbPool.read`, `TokenAccount.filter(TokenAccount.Columns.mintAddress == mintAddress).fetchOne(db)`. Uses `try!`.
  - `allTokenAccounts() -> [TokenAccount]` — `dbPool.read`, `TokenAccount.fetchAll(db)`. Uses `try!`.
  - `tokenAccounts(mintAddresses:) -> [TokenAccount]` — `dbPool.read`, `TokenAccount.filter(mintAddresses.contains(TokenAccount.Columns.mintAddress)).fetchAll(db)`. Uses `try!`.
  - `tokenAccountExists(mintAddress:) -> Bool` — `dbPool.read`, check `fetchOne` != nil. Uses `try!`.
  - `fullTokenAccount(mintAddress:) -> FullTokenAccount?` — raw SQL join: `SELECT ta.*, ma.* FROM tokenAccounts AS ta LEFT JOIN mintAccounts AS ma ON ta.mintAddress = ma.address WHERE ta.mintAddress = ?`. Decode both `TokenAccount(row:)` and `MintAccount(row:)` from the same row using column scoping or prefixed aliases. Return `FullTokenAccount(tokenAccount:, mintAccount:)`. Uses `try!`.
  - `fullTokenAccounts() -> [FullTokenAccount]` — same join without WHERE. Uses `try!`.
  - **Syncer state:** `lastSyncedTransaction(syncSourceName:) -> LastSyncedTransaction?` and `save(lastSyncedTransaction:)` — simple fetch/save by `syncSourceName`. Mirror `MainStorage` pattern.

### Phase 3: Complex Queries

- [x] **Task 5: Implement paginated transaction queries with filters** (depends on Task 3)
  Files: `Sources/SolanaKit/Database/TransactionStorage.swift`
  Implement the private query builder and the three public query methods. Port the Android `TransactionStorage.getTransactions(typeCondition:joinTokenTransfers:fromHash:limit:)` pattern to GRDB raw SQL.

  **Private query builder** — `private func fetchTransactions(typeCondition: String?, joinTokenTransfers: Bool, fromHash: String?, limit: Int?) -> [FullTransaction]`:
  - Build SQL dynamically: `SELECT DISTINCT tx.* FROM transactions AS tx`
  - If `joinTokenTransfers`: append `LEFT JOIN tokenTransfers AS tt ON tx.hash = tt.transactionHash`
  - Build `WHERE` clauses array + `StatementArguments` array:
    - If `fromHash` provided: look up the from-transaction via `transaction(hash:)`. If found, add keyset pagination condition: `(tx.timestamp < ? OR (tx.timestamp = ? AND tx.hash < ?))` with arguments `[fromTx.timestamp, fromTx.timestamp, fromTx.hash]`. This is cursor-based (seek) pagination ordered by `(timestamp DESC, hash DESC)`.
    - If `typeCondition` provided: append it to WHERE clauses.
  - Append `ORDER BY tx.timestamp DESC, tx.hash DESC`
  - If `limit` provided: append `LIMIT <n>`
  - Execute via `dbPool.read { db in try Row.fetchAll(db.makeStatement(sql: sql), arguments: StatementArguments(args)) }` and map rows to `Transaction(row:)`.
  - For each returned `Transaction`, fetch its `TokenTransfer` rows: `TokenTransfer.filter(TokenTransfer.Columns.transactionHash == tx.hash).fetchAll(db)`. For each `TokenTransfer`, fetch its `MintAccount` via `MintAccount.filter(MintAccount.Columns.address == tt.mintAddress).fetchOne(db)`. Assemble `FullTokenTransfer` and then `FullTransaction`. Do all of this inside the same `dbPool.read` block for consistency.
  - Uses `try!` on the outer `dbPool.read`.

  **Public methods:**
  - `transactions(incoming: Bool?, fromHash: String?, limit: Int?) -> [FullTransaction]`:
    - `incoming == nil`: `typeCondition = nil`, `joinTokenTransfers = false`
    - `incoming == true`: `typeCondition = "((tx.amount IS NOT NULL AND tx.\\"to\\" = '<address>') OR tt.incoming)"`, `joinTokenTransfers = true`
    - `incoming == false`: `typeCondition = "((tx.amount IS NOT NULL AND tx.\\"from\\" = '<address>') OR NOT(tt.incoming))"`, `joinTokenTransfers = true`
    - Note: `from` and `to` are SQL reserved words — quote them with double-quotes in raw SQL.

  - `solTransactions(incoming: Bool?, fromHash: String?, limit: Int?) -> [FullTransaction]`:
    - `incoming == nil`: `typeCondition = "tx.amount IS NOT NULL"`, `joinTokenTransfers = false`
    - `incoming == true`: `typeCondition = "(tx.amount IS NOT NULL AND tx.\\"to\\" = '<address>')"`, `joinTokenTransfers = false`
    - `incoming == false`: `typeCondition = "(tx.amount IS NOT NULL AND tx.\\"from\\" = '<address>')"`, `joinTokenTransfers = false`

  - `splTransactions(mintAddress: String, incoming: Bool?, fromHash: String?, limit: Int?) -> [FullTransaction]`:
    - `incoming == nil`: `typeCondition = "tt.mintAddress = '<mint>'"`, `joinTokenTransfers = true`
    - `incoming == true`: `typeCondition = "(tt.mintAddress = '<mint>' AND tt.incoming)"`, `joinTokenTransfers = true`
    - `incoming == false`: `typeCondition = "(tt.mintAddress = '<mint>' AND NOT(tt.incoming))"`, `joinTokenTransfers = true`

  - `fullTransactions(hashes: [String]) -> [FullTransaction]`:
    - No pagination, no order requirement. Filter `tx.hash IN (?, ?, ...)` with parameterized placeholders. Join token transfers + mint accounts same as the builder. Return assembled `[FullTransaction]`.

  The `address` string (owner wallet address) is needed for direction filtering. Store it as `private let address: String` on `TransactionStorage`, passed via init (same pattern as Android's `TransactionStorage(database, address)`). Update both `init` methods to accept `address: String`.

- [x] **Task 6: Wire ITransactionStorage conformance** (depends on Tasks 3, 4, 5)
  Files: `Sources/SolanaKit/Database/TransactionStorage.swift`
  Add `extension TransactionStorage: ITransactionStorage` at the bottom of the file, same pattern as `extension MainStorage: IMainStorage`. All methods are already implemented in Tasks 3-5 — this extension simply declares conformance. If any method signature in the class differs slightly from the protocol, adjust to match. Verify that the protocol from Task 1 matches all implemented methods exactly.

## Commit Plan
- **Commit 1** (after tasks 1-2): "Add ITransactionStorage protocol and TransactionStorage schema migrations"
- **Commit 2** (after tasks 3-4): "Implement transaction, token, and mint account CRUD in TransactionStorage"
- **Commit 3** (after tasks 5-6): "Add paginated transaction queries with direction and mint filters"
