import GRDB

/// GRDB record tracking whether the initial full transaction sync has completed.
///
/// Singleton-row table: only one row is ever stored per wallet database.
/// Once `synced` is `true`, `TransactionSyncer` switches to incremental cursor-based sync.
/// Mirrors Android's `InitialSyncEntity` simplified to the singleton-row pattern.
class InitialSyncEntity: Record {
    private static let primaryKeyValue = "primaryKey"
    private let primaryKey: String = InitialSyncEntity.primaryKeyValue

    /// `true` after the initial full transaction history fetch has completed.
    var synced: Bool

    // MARK: - Init

    init(synced: Bool) {
        self.synced = synced
        super.init()
    }

    // MARK: - Record

    override class var databaseTableName: String {
        "initialSyncs"
    }

    enum Columns: String, ColumnExpression {
        case primaryKey
        case synced
    }

    required init(row: Row) throws {
        synced = row[Columns.synced]
        try super.init(row: row)
    }

    override func encode(to container: inout PersistenceContainer) throws {
        container[Columns.primaryKey] = primaryKey
        container[Columns.synced] = synced
    }
}
