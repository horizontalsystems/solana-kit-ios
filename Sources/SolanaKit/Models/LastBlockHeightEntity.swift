import GRDB

/// GRDB record for the last known Solana block height (slot).
///
/// Singleton-row table: only one row is ever stored per wallet database.
/// Mirrors Android's `LastBlockHeightEntity` and follows EvmKit's `BlockchainState` pattern.
class LastBlockHeightEntity: Record {
    private static let primaryKeyValue = "primaryKey"
    private let primaryKey: String = LastBlockHeightEntity.primaryKeyValue

    /// The last confirmed block height (slot number) seen by `ApiSyncer`.
    var height: Int64

    // MARK: - Init

    init(height: Int64) {
        self.height = height
        super.init()
    }

    // MARK: - Record

    override class var databaseTableName: String {
        "lastBlockHeights"
    }

    enum Columns: String, ColumnExpression {
        case primaryKey
        case height
    }

    required init(row: Row) throws {
        height = row[Columns.height]
        try super.init(row: row)
    }

    override func encode(to container: inout PersistenceContainer) throws {
        container[Columns.primaryKey] = primaryKey
        container[Columns.height] = height
    }
}
