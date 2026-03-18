import Foundation
import GRDB

/// GRDB record for the native SOL balance of the watched address.
///
/// Singleton-row table: only one row is ever stored per wallet database.
/// Mirrors Android's `BalanceEntity` and follows EvmKit's `AccountState` pattern.
class BalanceEntity: Record {
    private static let primaryKeyValue = "primaryKey"
    private let primaryKey: String = BalanceEntity.primaryKeyValue

    /// Raw balance in lamports (1 SOL = 1 000 000 000 lamports).
    var lamports: Int64

    /// SOL balance derived from `lamports`.
    var balance: Decimal {
        Decimal(lamports) / 1_000_000_000
    }

    // MARK: - Init

    init(lamports: Int64) {
        self.lamports = lamports
        super.init()
    }

    // MARK: - Record

    override class var databaseTableName: String {
        "balances"
    }

    enum Columns: String, ColumnExpression {
        case primaryKey
        case lamports
    }

    required init(row: Row) throws {
        lamports = row[Columns.lamports]
        try super.init(row: row)
    }

    override func encode(to container: inout PersistenceContainer) throws {
        container[Columns.primaryKey] = primaryKey
        container[Columns.lamports] = lamports
    }
}
