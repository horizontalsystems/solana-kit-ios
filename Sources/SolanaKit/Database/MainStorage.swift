import Foundation
import GRDB

/// GRDB-backed storage for the main wallet database.
///
/// Stores three singleton-row tables:
/// - `balances` — cached SOL balance in lamports
/// - `lastBlockHeights` — last known block height (slot)
/// - `initialSyncs` — flag set once the initial full transaction sync completes
///
/// Each wallet gets its own database file (`main-<walletId>.sqlite`) so no
/// `address` parameter is needed — it is implicit in the file path.
///
/// Follows EvmKit's `ApiStorage` pattern: `DatabasePool` opened with `try!`,
/// migrations run with `try?`, reads with `try!`, writes propagate `throws`.
final class MainStorage {
    private let dbPool: DatabasePool

    // MARK: - Init

    init(databaseDirectoryUrl: URL, databaseFileName: String) {
        let databaseURL = databaseDirectoryUrl
            .appendingPathComponent("\(databaseFileName).sqlite")

        dbPool = try! DatabasePool(path: databaseURL.path)

        try? migrator.migrate(dbPool)
    }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createMainTables") { db in
            // balances — singleton-row, stores lamports as INTEGER
            try db.create(table: BalanceEntity.databaseTableName) { t in
                t.column(BalanceEntity.Columns.primaryKey.name, .text).notNull()
                t.column(BalanceEntity.Columns.lamports.name, .integer).notNull()
                t.primaryKey([BalanceEntity.Columns.primaryKey.name], onConflict: .replace)
            }

            // lastBlockHeights — singleton-row, stores slot as INTEGER
            try db.create(table: LastBlockHeightEntity.databaseTableName) { t in
                t.column(LastBlockHeightEntity.Columns.primaryKey.name, .text).notNull()
                t.column(LastBlockHeightEntity.Columns.height.name, .integer).notNull()
                t.primaryKey([LastBlockHeightEntity.Columns.primaryKey.name], onConflict: .replace)
            }

            // initialSyncs — singleton-row, stores synced flag as BOOLEAN
            try db.create(table: InitialSyncEntity.databaseTableName) { t in
                t.column(InitialSyncEntity.Columns.primaryKey.name, .text).notNull()
                t.column(InitialSyncEntity.Columns.synced.name, .boolean).notNull()
                t.primaryKey([InitialSyncEntity.Columns.primaryKey.name], onConflict: .replace)
            }
        }

        return migrator
    }

    // MARK: - Convenience initializer (wallet-scoped)

    /// Creates (or opens) the main database for the given wallet under
    /// `Application Support/solana-kit/main-<walletId>.sqlite`.
    convenience init(walletId: String) throws {
        let fileManager = FileManager.default
        let url = try fileManager
            .url(for: .applicationSupportDirectory,
                 in: .userDomainMask,
                 appropriateFor: nil,
                 create: true)
            .appendingPathComponent("solana-kit", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        self.init(databaseDirectoryUrl: url, databaseFileName: "main-\(walletId)")
    }

    // MARK: - Static cleanup

    /// Removes all database files for the given wallet.
    /// Mirrors Android's `SolanaDatabaseManager.clear()`.
    /// Called by `Kit.clear(walletId:)` during wallet removal.
    static func clear(walletId: String) throws {
        let fileManager = FileManager.default
        let url = try fileManager
            .url(for: .applicationSupportDirectory,
                 in: .userDomainMask,
                 appropriateFor: nil,
                 create: true)
            .appendingPathComponent("solana-kit", isDirectory: true)

        let baseName = "main-\(walletId)"
        let extensions = ["sqlite", "sqlite-wal", "sqlite-shm"]

        for ext in extensions {
            let fileURL = url.appendingPathComponent("\(baseName).\(ext)")
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }
}

// MARK: - IMainStorage

extension MainStorage: IMainStorage {
    func balance() -> Int64? {
        try! dbPool.read { db in
            try BalanceEntity.fetchOne(db)?.lamports
        }
    }

    func save(balance: Int64) throws {
        try dbPool.write { db in
            let entity = try BalanceEntity.fetchOne(db) ?? BalanceEntity(lamports: 0)
            entity.lamports = balance
            try entity.save(db)
        }
    }

    func lastBlockHeight() -> Int64? {
        try! dbPool.read { db in
            try LastBlockHeightEntity.fetchOne(db)?.height
        }
    }

    func save(lastBlockHeight: Int64) throws {
        try dbPool.write { db in
            let entity = try LastBlockHeightEntity.fetchOne(db) ?? LastBlockHeightEntity(height: 0)
            entity.height = lastBlockHeight
            try entity.save(db)
        }
    }

    func initialSynced() -> Bool {
        try! dbPool.read { db in
            try InitialSyncEntity.fetchOne(db)?.synced ?? false
        }
    }

    func setInitialSynced() throws {
        try dbPool.write { db in
            let entity = InitialSyncEntity(synced: true)
            try entity.save(db)
        }
    }
}
