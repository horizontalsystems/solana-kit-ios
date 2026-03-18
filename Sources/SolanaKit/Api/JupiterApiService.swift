import Alamofire
import Foundation
import HsToolKit

/// REST client for the Jupiter token registry API.
///
/// Endpoint: `GET https://api.jup.ag/tokens/v2/search?query=<mintAddress>`
///
/// Mirrors Android's `JupiterApiService.kt`, adapted for Swift + HsToolKit's `NetworkManager`.
final class JupiterApiService: IJupiterApiService {

    // MARK: - Dependencies

    private let networkManager: NetworkManager
    private let apiKey: String?

    // MARK: - Constants

    private let baseUrl = URL(string: "https://api.jup.ag/tokens/v2/search")!

    // MARK: - Init

    /// - Parameters:
    ///   - networkManager: HsToolKit networking layer.
    ///   - apiKey: Optional Jupiter API key. When provided, it is sent as `x-api-key` header.
    init(networkManager: NetworkManager, apiKey: String? = nil) {
        self.networkManager = networkManager
        self.apiKey = apiKey
    }

    // MARK: - IJupiterApiService

    /// Fetches token metadata from the Jupiter search endpoint.
    ///
    /// - Parameter mintAddress: Base58 mint address string to search for.
    /// - Returns: `TokenInfo` from the first matching result.
    /// - Throws: `JupiterError.tokenNotFound` when the response array is empty.
    func tokenInfo(mintAddress: String) async throws -> TokenInfo {
        var headers = HTTPHeaders()
        if let apiKey = apiKey {
            headers.add(name: "x-api-key", value: apiKey)
        }

        let json = try await networkManager.fetchJson(
            url: baseUrl,
            method: .get,
            parameters: ["query": mintAddress],
            encoding: URLEncoding.queryString,
            headers: headers,
            interceptor: nil,
            responseCacherBehavior: .doNotCache
        )

        guard let array = json as? [[String: Any]] else {
            throw JupiterError.invalidResponse
        }

        guard let first = array.first else {
            throw JupiterError.tokenNotFound(mintAddress: mintAddress)
        }

        let data = try JSONSerialization.data(withJSONObject: first)
        let token = try JSONDecoder().decode(JupiterToken.self, from: data)

        return TokenInfo(name: token.name, symbol: token.symbol, decimals: token.decimals)
    }
}

// MARK: - Private types

private extension JupiterApiService {

    struct JupiterToken: Codable {
        let address: String
        let name: String
        let symbol: String
        let decimals: Int
    }
}

// MARK: - Errors

extension JupiterApiService {
    enum JupiterError: Error {
        case invalidResponse
        case tokenNotFound(mintAddress: String)
    }
}
