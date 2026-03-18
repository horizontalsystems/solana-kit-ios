import Foundation
import GRDB

/// GRDB record for an SPL token transfer event within a transaction.
///
/// Multiple `TokenTransfer` rows can belong to one `Transaction` (one-to-many via `transactionHash`).
/// An index on `transactionHash` is created in the migration for efficient joins.
/// First-write-wins conflict policy mirrors Android's `@Insert(onConflict = OnConflictStrategy.IGNORE)`.
///
/// **Migration note:** The `transactionHash` column must be declared as a foreign key to
/// `transactions(hash)` with `ON DELETE CASCADE` — mirrors Android's Room `ForeignKey` definition.
/// Use `t.column(Columns.transactionHash.name, .text).references("transactions", onDelete: .cascade)`
/// in `TransactionStorage`'s GRDB migrator.
public class TokenTransfer: Record {
    /// Auto-incremented row identifier; `nil` before the first insert.
    public var id: Int64?
    /// Foreign key to `Transaction.hash`.
    public var transactionHash: String
    /// Mint address of the SPL token being transferred.
    public var mintAddress: String
    /// `true` when tokens were received by the watched address; `false` when sent.
    public var incoming: Bool
    /// Transfer amount stored as a `String` to avoid floating-point precision loss.
    public var amount: String

    /// Transfer amount as `Decimal`.
    public var decimalAmount: Decimal {
        Decimal(string: amount) ?? 0
    }

    // MARK: - Init

    init(
        id: Int64? = nil,
        transactionHash: String,
        mintAddress: String,
        incoming: Bool,
        amount: String
    ) {
        self.id = id
        self.transactionHash = transactionHash
        self.mintAddress = mintAddress
        self.incoming = incoming
        self.amount = amount
        super.init()
    }

    // MARK: - Record

    public override class var databaseTableName: String { "tokenTransfers" }

    /// First-write-wins: mirrors Android's `OnConflictStrategy.IGNORE`.
    public override class var persistenceConflictPolicy: PersistenceConflictPolicy {
        PersistenceConflictPolicy(insert: .ignore, update: .ignore)
    }

    enum Columns: String, ColumnExpression {
        case id
        case transactionHash
        case mintAddress
        case incoming
        case amount
    }

    public required init(row: Row) throws {
        id = row[Columns.id]
        transactionHash = row[Columns.transactionHash]
        mintAddress = row[Columns.mintAddress]
        incoming = row[Columns.incoming]
        amount = row[Columns.amount]
        try super.init(row: row)
    }

    public override func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.transactionHash] = transactionHash
        container[Columns.mintAddress] = mintAddress
        container[Columns.incoming] = incoming
        container[Columns.amount] = amount
    }

    /// Captures the auto-assigned rowid after insert.
    public override func didInsert(_ inserted: InsertionSuccess) {
        super.didInsert(inserted)
        id = inserted.rowID
    }
}
