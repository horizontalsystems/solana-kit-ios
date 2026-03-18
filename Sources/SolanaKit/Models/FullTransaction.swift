/// In-memory composite of a `Transaction` with its associated SPL token transfers.
///
/// Part of the Kit's public API surface — emitted by `kit.transactionsPublisher` and
/// returned by `kit.transactions(fromHash:limit:)`.
///
/// Assembled from separate DB fetches of `Transaction` + `TokenTransfer` + `MintAccount`,
/// mirroring Android's `FullTransaction` data class and the two-level nested `@Relation`
/// pattern in `TransactionsDao`.
public struct FullTransaction {
    /// The raw transaction record (signature, timestamps, SOL transfer amounts, etc.).
    public let transaction: Transaction
    /// All SPL token transfers that occurred within this transaction.
    public let tokenTransfers: [FullTokenTransfer]
}
