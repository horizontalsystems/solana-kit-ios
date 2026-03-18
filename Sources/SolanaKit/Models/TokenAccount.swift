import Foundation
import GRDB

/// GRDB record for a Solana SPL token account (Associated Token Account / ATA).
///
/// Each row represents one SPL token account owned by the watched address.
/// Upsert conflict policy mirrors Android's `@Insert(onConflict = OnConflictStrategy.REPLACE)`.
public class TokenAccount: Record {
    /// The SPL token account address (ATA address) — primary key.
    public var address: String
    /// The mint address this account holds tokens for; foreign key to `MintAccount.address`.
    public var mintAddress: String
    /// Raw token balance stored as a `String` to avoid floating-point precision loss.
    /// Mirrors Android's `BigDecimal` stored via `RoomTypeConverters`.
    public var balance: String
    /// Number of decimal places for the token (cached from mint for display convenience).
    public var decimals: Int

    /// Token balance as `Decimal` derived from the stored string representation.
    public var decimalBalance: Decimal {
        Decimal(string: balance) ?? 0
    }

    // MARK: - Init

    init(address: String, mintAddress: String, balance: String, decimals: Int) {
        self.address = address
        self.mintAddress = mintAddress
        self.balance = balance
        self.decimals = decimals
        super.init()
    }

    // MARK: - Record

    public override class var databaseTableName: String { "tokenAccounts" }

    /// Upsert: mirrors Android's `OnConflictStrategy.REPLACE`.
    public override class var persistenceConflictPolicy: PersistenceConflictPolicy {
        PersistenceConflictPolicy(insert: .replace, update: .replace)
    }

    enum Columns: String, ColumnExpression {
        case address
        case mintAddress
        case balance
        case decimals
    }

    public required init(row: Row) throws {
        address = row[Columns.address]
        mintAddress = row[Columns.mintAddress]
        balance = row[Columns.balance]
        decimals = row[Columns.decimals]
        try super.init(row: row)
    }

    public override func encode(to container: inout PersistenceContainer) throws {
        container[Columns.address] = address
        container[Columns.mintAddress] = mintAddress
        container[Columns.balance] = balance
        container[Columns.decimals] = decimals
    }
}
