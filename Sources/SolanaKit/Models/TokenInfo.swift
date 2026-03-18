import Foundation

/// Token name/symbol/decimals metadata from the Jupiter API.
///
/// Mirrors Android's `TokenInfo.kt` data class.
struct TokenInfo {
    let name: String
    let symbol: String
    let decimals: Int
}
