/// In-memory composite of a `TokenTransfer` with its associated `MintAccount`.
///
/// Assembled by `TransactionStorage` queries that join `tokenTransfers` and `mintAccounts`
/// on `mintAddress`. Not persisted — never conforms to any GRDB protocol.
/// Mirrors Android's `FullTokenTransfer` data class and the `@Relation` pattern in `TransactionsDao`.
public struct FullTokenTransfer {
    /// The raw token transfer record.
    public let tokenTransfer: TokenTransfer
    /// The mint metadata for the transferred token.
    public let mintAccount: MintAccount
}
