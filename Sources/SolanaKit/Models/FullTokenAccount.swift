/// In-memory composite of a `TokenAccount` with its associated `MintAccount`.
///
/// Part of the Kit's public API surface — emitted by `kit.fungibleTokenAccountsPublisher` and
/// returned by `kit.fungibleTokenAccounts()`.
///
/// Assembled from `TokenAccount` + `MintAccount` joined in memory on `mintAddress`.
/// Mirrors Android's `FullTokenAccount` data class.
public struct FullTokenAccount {
    /// The SPL token account record (address, balance, decimals).
    public let tokenAccount: TokenAccount
    /// The mint metadata for the token held in this account.
    public let mintAccount: MintAccount
}
