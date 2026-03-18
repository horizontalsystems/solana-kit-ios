import Foundation
import GRDB

/// GRDB record for a Solana transaction (SOL transfer or SPL token transfer wrapper).
///
/// Covers both confirmed transactions (fetched from chain history) and pending transactions
/// (locally constructed and broadcast, awaiting confirmation).
/// Upsert conflict policy mirrors Android's `@Insert(onConflict = OnConflictStrategy.REPLACE)`.
public class Transaction: Record {
    /// Transaction signature — primary key.
    public var hash: String
    /// Unix timestamp in seconds when the transaction was confirmed.
    public var timestamp: Int64
    /// Transaction fee in lamports stored as a `String` to avoid precision loss; `nil` if unknown.
    public var fee: String?
    /// Sender address; `nil` for non-transfer transactions.
    public var from: String?
    /// Recipient address; `nil` for non-transfer transactions.
    public var to: String?
    /// Transfer amount in lamports stored as a `String`; `nil` for non-transfer transactions.
    public var amount: String?
    /// Error message if the transaction failed on-chain; `nil` for successful transactions.
    public var error: String?
    /// `true` while the transaction is unconfirmed (pending broadcast or awaiting finalization).
    public var pending: Bool
    /// Recent blockhash embedded in the transaction; used for pending-tx resend flow.
    public var blockHash: String
    /// Last valid block height for the blockhash; used for pending-tx expiry check.
    public var lastValidBlockHeight: Int64
    /// Base64-encoded serialized transaction bytes; used for re-broadcasting pending transactions.
    public var base64Encoded: String
    /// Number of times this pending transaction has been re-broadcast.
    public var retryCount: Int

    /// Transaction fee as `Decimal`, or `nil` if `fee` is not set.
    public var decimalFee: Decimal? {
        fee.flatMap { Decimal(string: $0) }
    }

    /// Transfer amount as `Decimal`, or `nil` if `amount` is not set.
    public var decimalAmount: Decimal? {
        amount.flatMap { Decimal(string: $0) }
    }

    // MARK: - Init

    init(
        hash: String,
        timestamp: Int64,
        fee: String? = nil,
        from: String? = nil,
        to: String? = nil,
        amount: String? = nil,
        error: String? = nil,
        pending: Bool = true,
        blockHash: String = "",
        lastValidBlockHeight: Int64 = 0,
        base64Encoded: String = "",
        retryCount: Int = 0
    ) {
        self.hash = hash
        self.timestamp = timestamp
        self.fee = fee
        self.from = from
        self.to = to
        self.amount = amount
        self.error = error
        self.pending = pending
        self.blockHash = blockHash
        self.lastValidBlockHeight = lastValidBlockHeight
        self.base64Encoded = base64Encoded
        self.retryCount = retryCount
        super.init()
    }

    // MARK: - Record

    override class var databaseTableName: String { "transactions" }

    /// Upsert: mirrors Android's `OnConflictStrategy.REPLACE`.
    override class var persistenceConflictPolicy: PersistenceConflictPolicy {
        PersistenceConflictPolicy(insert: .replace, update: .replace)
    }

    enum Columns: String, ColumnExpression {
        case hash
        case timestamp
        case fee
        case from
        case to
        case amount
        case error
        case pending
        case blockHash
        case lastValidBlockHeight
        case base64Encoded
        case retryCount
    }

    required init(row: Row) throws {
        hash = row[Columns.hash]
        timestamp = row[Columns.timestamp]
        fee = row[Columns.fee]
        from = row[Columns.from]
        to = row[Columns.to]
        amount = row[Columns.amount]
        error = row[Columns.error]
        pending = row[Columns.pending]
        blockHash = row[Columns.blockHash]
        lastValidBlockHeight = row[Columns.lastValidBlockHeight]
        base64Encoded = row[Columns.base64Encoded]
        retryCount = row[Columns.retryCount]
        try super.init(row: row)
    }

    override func encode(to container: inout PersistenceContainer) throws {
        container[Columns.hash] = hash
        container[Columns.timestamp] = timestamp
        container[Columns.fee] = fee
        container[Columns.from] = from
        container[Columns.to] = to
        container[Columns.amount] = amount
        container[Columns.error] = error
        container[Columns.pending] = pending
        container[Columns.blockHash] = blockHash
        container[Columns.lastValidBlockHeight] = lastValidBlockHeight
        container[Columns.base64Encoded] = base64Encoded
        container[Columns.retryCount] = retryCount
    }
}
