import Foundation

/// Token name/symbol/decimals metadata from the Jupiter API.
///
/// Mirrors Android's `TokenInfo.kt` data class.
public struct TokenInfo {
    public let name: String
    public let symbol: String
    public let decimals: Int
}
