import Foundation

/// A single entry returned by `getSignaturesForAddress`.
///
/// Mirrors Android's `SignatureInfo` data class in `SolanaKT`.
struct SignatureInfo: Decodable {
    /// Non-nil when the transaction failed. Only checked for presence.
    let err: AnyCodable?
    let memo: String?
    let signature: String
    let slot: Int64?
    let blockTime: Int64?
}
