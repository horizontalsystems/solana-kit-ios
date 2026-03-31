import Foundation

/// Abstraction for fetching new transaction signatures.
///
/// Implementations can use Solana RPC `getSignaturesForAddress`, Helius DAS API,
/// or any other indexer. Each provider fully owns its sync cursors —
/// reads them at fetch start, writes them at fetch end.
protocol ISignatureProvider {
    /// Fetches all new signatures since the provider's last saved cursor.
    /// On success, the provider saves its cursor(s) internally before returning.
    func fetchNewSignatures() async throws -> [SignatureInfo]
}
