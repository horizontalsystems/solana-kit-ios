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
    private let swapBaseUrl = URL(string: "https://api.jup.ag/swap/v1")!

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

    /// Fetches a swap quote from Jupiter's v6 `/quote` endpoint.
    ///
    /// - Parameters:
    ///   - inputMint: Base58 address of the token being sold.
    ///   - outputMint: Base58 address of the token being bought.
    ///   - amount: Input token amount in the token's smallest unit (e.g. lamports for SOL).
    ///   - slippageBps: Maximum allowed slippage in basis points (e.g. 50 = 0.5%).
    /// - Returns: `JupiterQuoteResponse` containing the best route and expected output amount.
    /// - Throws: `JupiterError.quoteNotAvailable` if no route is found or the response is invalid.
    func quote(inputMint: String, outputMint: String, amount: UInt64, slippageBps: Int) async throws -> JupiterQuoteResponse {
        var headers = HTTPHeaders()
        if let apiKey = apiKey {
            headers.add(name: "x-api-key", value: apiKey)
        }

        let json = try await networkManager.fetchJson(
            url: swapBaseUrl.appendingPathComponent("quote"),
            method: .get,
            parameters: [
                "inputMint": inputMint,
                "outputMint": outputMint,
                "amount": String(amount),
                "slippageBps": slippageBps,
            ],
            encoding: URLEncoding.queryString,
            headers: headers,
            interceptor: nil,
            responseCacherBehavior: .doNotCache
        )

        guard let dict = json as? [String: Any] else {
            throw JupiterError.quoteNotAvailable
        }

        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(JupiterQuoteResponse.self, from: data)
    }

    /// Builds a swap transaction via Jupiter's v6 `/swap` endpoint.
    ///
    /// The returned `JupiterSwapResponse.swapTransaction` is a base64-encoded V0 versioned
    /// transaction that the caller must decode, sign, and broadcast via `kit.sendRawTransaction`.
    ///
    /// - Parameters:
    ///   - quoteResponse: Quote obtained from `quote(inputMint:outputMint:amount:slippageBps:)`.
    ///   - userPublicKey: Base58 public key of the fee-payer / signer wallet.
    ///   - prioritizationMaxLamports: When provided, adds a Compute Budget priority fee capped
    ///     at this amount using "medium" priority level. Pass `nil` for no prioritization fee.
    /// - Returns: `JupiterSwapResponse` containing the base64-encoded transaction.
    /// - Throws: `JupiterError.swapFailed` if the API returns an error response.
    func swap(quoteResponse: JupiterQuoteResponse, userPublicKey: String, prioritizationMaxLamports: Int64? = nil) async throws -> JupiterSwapResponse {
        let prioritizationFee: JupiterSwapRequest.PrioritizationFee? = prioritizationMaxLamports.map { maxLamports in
            JupiterSwapRequest.PrioritizationFee(
                priorityLevelWithMaxLamports: JupiterSwapRequest.PriorityLevelConfig(
                    maxLamports: maxLamports,
                    priorityLevel: "medium"
                )
            )
        }

        let swapRequest = JupiterSwapRequest(
            quoteResponse: quoteResponse,
            userPublicKey: userPublicKey,
            wrapAndUnwrapSol: true,
            dynamicComputeUnitLimit: true,
            dynamicSlippage: nil,
            prioritizationFeeLamports: prioritizationFee
        )

        var urlRequest = URLRequest(url: swapBaseUrl.appendingPathComponent("swap"))
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try JSONEncoder().encode(swapRequest)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = apiKey {
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw JupiterError.swapFailed(message)
        }

        return try JSONDecoder().decode(JupiterSwapResponse.self, from: data)
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
        case quoteNotAvailable
        case swapFailed(String)
    }
}
