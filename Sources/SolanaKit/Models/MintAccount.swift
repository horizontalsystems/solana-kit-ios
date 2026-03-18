import Foundation
import GRDB

/// GRDB record for a Solana SPL token mint account.
///
/// Stores mint metadata (decimals, supply) and optional enrichment from SolanaFM
/// (name, symbol, URI, collection address). First-write-wins conflict policy mirrors
/// Android's `@Insert(onConflict = OnConflictStrategy.IGNORE)`.
public class MintAccount: Record {
    /// The mint address — primary key.
    public var address: String
    /// Number of decimal places for the token.
    public var decimals: Int
    /// Total supply of the token; `nil` if not fetched.
    public var supply: Int64?
    /// `true` when the mint represents an NFT (supply == 1, decimals == 0).
    public var isNft: Bool
    /// Human-readable token name from SolanaFM metadata enrichment.
    public var name: String?
    /// Token symbol from SolanaFM metadata enrichment.
    public var symbol: String?
    /// Metadata URI (JSON) from SolanaFM metadata enrichment.
    public var uri: String?
    /// NFT collection mint address from SolanaFM metadata enrichment.
    public var collectionAddress: String?

    // MARK: - Init

    init(
        address: String,
        decimals: Int,
        supply: Int64? = nil,
        isNft: Bool = false,
        name: String? = nil,
        symbol: String? = nil,
        uri: String? = nil,
        collectionAddress: String? = nil
    ) {
        self.address = address
        self.decimals = decimals
        self.supply = supply
        self.isNft = isNft
        self.name = name
        self.symbol = symbol
        self.uri = uri
        self.collectionAddress = collectionAddress
        super.init()
    }

    // MARK: - Record

    override class var databaseTableName: String { "mintAccounts" }

    /// First-write-wins: mirrors Android's `OnConflictStrategy.IGNORE`.
    override class var persistenceConflictPolicy: PersistenceConflictPolicy {
        PersistenceConflictPolicy(insert: .ignore, update: .ignore)
    }

    enum Columns: String, ColumnExpression {
        case address
        case decimals
        case supply
        case isNft
        case name
        case symbol
        case uri
        case collectionAddress
    }

    required init(row: Row) throws {
        address = row[Columns.address]
        decimals = row[Columns.decimals]
        supply = row[Columns.supply]
        isNft = row[Columns.isNft]
        name = row[Columns.name]
        symbol = row[Columns.symbol]
        uri = row[Columns.uri]
        collectionAddress = row[Columns.collectionAddress]
        try super.init(row: row)
    }

    override func encode(to container: inout PersistenceContainer) throws {
        container[Columns.address] = address
        container[Columns.decimals] = decimals
        container[Columns.supply] = supply
        container[Columns.isNft] = isNft
        container[Columns.name] = name
        container[Columns.symbol] = symbol
        container[Columns.uri] = uri
        container[Columns.collectionAddress] = collectionAddress
    }
}
