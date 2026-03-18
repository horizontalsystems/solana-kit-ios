# Plan: MainStorage (GRDB)

## Context

Create the first database access layer — `MainStorage.swift` — that provides schema creation, migrations, and read/write methods for balance, last block height, and initial sync flag. This is the sole access point for the main database, following EvmKit's `ApiStorage` pattern and implementing the `IMainStorage` protocol defined in the architecture.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Protocol definition

- [x] **Task 1: Define IMainStorage protocol in Protocols.swift**
  Files: `Sources/SolanaKit/Core/Protocols.swift`
  Create the `Core/` directory and `Protocols.swift` file. Define the `IMainStorage` protocol exactly as specified in ARCHITECTURE.md:
  ```swift
  protocol IMainStorage {
      func balance() -> Int64?
      func save(balance: Int64) throws
      func lastBlockHeight() -> Int64?
      func save(lastBlockHeight: Int64) throws
      func initialSynced() -> Bool
      func setInitialSynced() throws
  }
  ```
  Use `Int64` for balance (lamports) and last block height to match the entity types already defined in `BalanceEntity` and `LastBlockHeightEntity`. The protocol uses simplified signatures (no `address` parameter) because the main database is per-wallet — each wallet gets its own database file, so the address is implicit. This matches EvmKit's `IApiStorage` pattern where `lastBlockHeight` and `accountState` take no arguments.

### Phase 2: Storage implementation

- [x] **Task 2: Create MainStorage with DatabasePool and migrations** (depends on Task 1)
  Files: `Sources/SolanaKit/Database/MainStorage.swift`
  Create the `Database/` directory and `MainStorage.swift`. Follow EvmKit's `ApiStorage` as the structural template:

  1. **DatabasePool init**: Accept `databaseDirectoryUrl: URL` and `databaseFileName: String` parameters (same signature as EvmKit's `ApiStorage.init`). Construct the `.sqlite` path, create `DatabasePool` with `try!`, then run `try? migrator.migrate(dbPool)`.

  2. **Computed `var migrator: DatabaseMigrator`**: Register a single migration `"createMainTables"` that creates all three tables:
     - `balances` table: `primaryKey` TEXT NOT NULL + `lamports` INTEGER NOT NULL, primary key on `primaryKey` with `onConflict: .replace`. Use `BalanceEntity.databaseTableName` and `BalanceEntity.Columns` for column names.
     - `lastBlockHeights` table: `primaryKey` TEXT NOT NULL + `height` INTEGER NOT NULL, primary key on `primaryKey` with `onConflict: .replace`. Use `LastBlockHeightEntity.databaseTableName` and `LastBlockHeightEntity.Columns`.
     - `initialSyncs` table: `primaryKey` TEXT NOT NULL + `synced` BOOLEAN NOT NULL, primary key on `primaryKey` with `onConflict: .replace`. Use `InitialSyncEntity.databaseTableName` and `InitialSyncEntity.Columns`.

  Group all three tables in one migration since this is the initial schema (no prior versions to migrate from). All three tables use the singleton-row pattern (fixed `primaryKey` string, `onConflict: .replace`).

- [x] **Task 3: Implement IMainStorage conformance on MainStorage** (depends on Task 2)
  Files: `Sources/SolanaKit/Database/MainStorage.swift`
  Add `extension MainStorage: IMainStorage` with all six methods, following EvmKit's `ApiStorage` read/write patterns:

  - `func balance() -> Int64?` — `try! dbPool.read { db in try BalanceEntity.fetchOne(db)?.lamports }`
  - `func save(balance: Int64) throws` — fetch-or-create `BalanceEntity`, set `lamports`, call `try entity.save(db)` inside `try dbPool.write { }`. Use `try` (not `try?`) so the caller can handle errors.
  - `func lastBlockHeight() -> Int64?` — `try! dbPool.read { db in try LastBlockHeightEntity.fetchOne(db)?.height }`
  - `func save(lastBlockHeight: Int64) throws` — same fetch-or-create pattern as balance, set `height`, save.
  - `func initialSynced() -> Bool` — `try! dbPool.read { db in try InitialSyncEntity.fetchOne(db)?.synced ?? false }`
  - `func setInitialSynced() throws` — create `InitialSyncEntity(synced: true)`, save.

  Read methods use `try!` (force-try, database errors = programmer error, same as EvmKit). Write methods propagate `throws` to let callers decide error handling.

### Phase 3: Database directory helper

- [x] **Task 4: Add static database directory helper for Kit wiring** (depends on Task 2)
  Files: `Sources/SolanaKit/Database/MainStorage.swift`
  Add a static convenience initializer or factory that encapsulates the directory setup, matching how EvmKit's `Kit.swift` creates storage:
  ```swift
  convenience init(walletId: String) throws {
      let fileManager = FileManager.default
      let url = try fileManager
          .url(for: .applicationSupportDirectory, in: .userDomainMask,
               appropriateFor: nil, create: true)
          .appendingPathComponent("solana-kit", isDirectory: true)
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
      self.init(databaseDirectoryUrl: url, databaseFileName: "main-\(walletId)")
  }
  ```
  Also add a static `clear(walletId:)` method that deletes the database file (mirrors Android's `SolanaDatabaseManager.clear`). This will be called by `Kit.clear()` for wallet cleanup. Delete the `.sqlite`, `.sqlite-wal`, and `.sqlite-shm` files.
