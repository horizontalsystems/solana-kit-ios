import Foundation
import HsToolKit

/// Public entry point for on-demand SPL token metadata lookup.
///
/// Fetches name, symbol, and decimals for an arbitrary mint address via the Jupiter API.
/// Use this when a `Kit` instance is not available — for example, in the wallet's
/// "Add Token" flow where the user enters a mint address before a wallet session starts.
///
/// Mirrors Android's `TokenProvider.kt`.
///
/// ```swift
/// let provider = TokenProvider(networkManager: networkManager)
/// let info = try await provider.tokenInfo(mintAddress: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
/// print(info.symbol) // "USDC"
/// ```
public final class TokenProvider {

    // MARK: - Dependencies

    private let jupiterApiService: IJupiterApiService

    // MARK: - Init

    /// Creates a `TokenProvider` backed by a new `JupiterApiService` instance.
    ///
    /// - Parameters:
    ///   - networkManager: HsToolKit networking layer used to make HTTP requests.
    ///   - apiKey: Optional Jupiter API key. When provided it is sent as `x-api-key` header.
    public init(networkManager: NetworkManager, apiKey: String? = nil) {
        self.jupiterApiService = JupiterApiService(networkManager: networkManager, apiKey: apiKey)
    }

    // MARK: - Public API

    /// Fetches token metadata for the given mint address.
    ///
    /// - Parameter mintAddress: Base58-encoded SPL token mint address.
    /// - Returns: `TokenInfo` containing the token's name, symbol, and decimals.
    /// - Throws: `JupiterError.tokenNotFound` when no token matches the given mint address,
    ///   or `JupiterError.invalidResponse` on a malformed API response.
    public func tokenInfo(mintAddress: String) async throws -> TokenInfo {
        try await jupiterApiService.tokenInfo(mintAddress: mintAddress)
    }
}
