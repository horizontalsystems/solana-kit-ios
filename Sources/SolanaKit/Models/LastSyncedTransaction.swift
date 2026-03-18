import GRDB

/// GRDB record storing the incremental sync cursor for transaction history.
///
/// Each syncer (e.g. `TransactionSyncer`) writes one row keyed by its `syncSourceName`.
/// On the next sync cycle the cursor is read and passed as the `before` parameter to
/// `getSignaturesForAddress`, avoiding a full history re-fetch.
/// Upsert conflict policy mirrors Android's `@Insert(onConflict = OnConflictStrategy.REPLACE)`.
class LastSyncedTransaction: Record {
    /// Identifies which syncer owns this cursor — primary key.
    var syncSourceName: String
    /// The last synced transaction signature used as the cursor for incremental sync.
    var hash: String

    // MARK: - Init

    init(syncSourceName: String, hash: String) {
        self.syncSourceName = syncSourceName
        self.hash = hash
        super.init()
    }

    // MARK: - Record

    override class var databaseTableName: String { "lastSyncedTransactions" }

    /// Upsert: mirrors Android's `OnConflictStrategy.REPLACE`.
    override class var persistenceConflictPolicy: PersistenceConflictPolicy {
        PersistenceConflictPolicy(insert: .replace, update: .replace)
    }

    enum Columns: String, ColumnExpression {
        case syncSourceName
        case hash
    }

    required init(row: Row) throws {
        syncSourceName = row[Columns.syncSourceName]
        hash = row[Columns.hash]
        try super.init(row: row)
    }

    override func encode(to container: inout PersistenceContainer) throws {
        container[Columns.syncSourceName] = syncSourceName
        container[Columns.hash] = hash
    }
}
