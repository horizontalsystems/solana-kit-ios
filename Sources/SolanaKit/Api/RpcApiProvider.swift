import Alamofire
import Foundation
import HsToolKit

class RpcApiProvider {
    private let networkManager: NetworkManager
    private let url: URL
    private let headers: HTTPHeaders

    private var currentRpcId = 0

    init(networkManager: NetworkManager, url: URL, auth: String?) {
        self.networkManager = networkManager
        self.url = url

        var headers = HTTPHeaders()

        if let auth {
            headers.add(.authorization(username: "", password: auth))
        }

        self.headers = headers
    }

    private func rpcResult<T>(rpc: JsonRpc<T>, parameters: [String: Any]) async throws -> T {
        let json = try await networkManager.fetchJson(
            url: url,
            method: .post,
            parameters: parameters,
            encoding: JSONEncoding.default,
            headers: headers,
            interceptor: self,
            responseCacherBehavior: .doNotCache
        )

        guard let rpcResponse = JsonRpcResponse.response(jsonObject: json) else {
            throw RequestError.invalidResponse(jsonObject: json)
        }

        return try rpc.parse(response: rpcResponse)
    }
}

// MARK: - IRpcApiProvider

extension RpcApiProvider: IRpcApiProvider {
    var source: String {
        url.host ?? url.absoluteString
    }

    func fetch<T>(rpc: JsonRpc<T>) async throws -> T {
        currentRpcId += 1
        return try await rpcResult(rpc: rpc, parameters: rpc.parameters(id: currentRpcId))
    }

    /// Sends a JSON-RPC batch request.
    ///
    /// Alamofire's `JSONEncoding` only supports `[String: Any]` as the top-level body,
    /// so this method builds the request manually with `URLSession`.
    ///
    /// Each `rpc` is assigned an `id` equal to its index (0-based).
    /// The returned array is parallel to the input: `result[i]` corresponds to `rpcs[i]`.
    /// A `nil` entry means the node returned no result for that request or parsing failed.
    func fetchBatch<T>(rpcs: [JsonRpc<T>]) async throws -> [T?] {
        guard !rpcs.isEmpty else { return [] }

        let requestArray = rpcs.enumerated().map { $0.element.parameters(id: $0.offset) }
        let bodyData = try JSONSerialization.data(withJSONObject: requestArray, options: [])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }

        let (data, _) = try await URLSession.shared.data(for: request)

        guard
            let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
            let responseArray = jsonObject as? [[String: Any]]
        else {
            throw RequestError.invalidResponse(jsonObject: data)
        }

        var results: [T?] = Array(repeating: nil, count: rpcs.count)
        for dict in responseArray {
            guard
                let id = dict["id"] as? Int,
                id >= 0, id < rpcs.count,
                let rpcResponse = JsonRpcResponse.response(jsonObject: dict)
            else { continue }

            results[id] = try? rpcs[id].parse(response: rpcResponse)
        }
        return results
    }
}

// MARK: - Batch Transaction Convenience

extension RpcApiProvider {
    /// Fetches multiple transactions by signature in parallel batch requests.
    ///
    /// Chunks `signatures` into groups of `batchChunkSize` (100, matching Android's
    /// `TransactionSyncer.batchChunkSize`), issues one batch RPC request per chunk,
    /// and returns a dictionary keyed by signature.
    ///
    /// Signatures for which the node returns null or a parse failure are omitted from the result.
    func fetchTransactionsBatch(signatures: [String]) async throws -> [String: RpcTransactionResponse] {
        let batchChunkSize = 100
        var result: [String: RpcTransactionResponse] = [:]

        let chunks = signatures.chunked(into: batchChunkSize)
        for chunk in chunks {
            let rpcs = chunk.map { GetTransactionJsonRpc(signature: $0) }
            let responses: [RpcTransactionResponse??] = try await fetchBatch(rpcs: rpcs)
            for (signature, maybeResponse) in zip(chunk, responses) {
                if let outerOpt = maybeResponse, let tx = outerOpt {
                    result[signature] = tx
                }
            }
        }

        return result
    }
}

// MARK: - Array chunk helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - RequestInterceptor (Alamofire retry)

extension RpcApiProvider: RequestInterceptor {
    func retry(_: Request, for _: Session, dueTo error: Error, completion: @escaping (RetryResult) -> Void) {
        if case let JsonRpcResponse.ResponseError.rpcError(rpcError) = error, rpcError.code == -32005 {
            var backoffSeconds = 1.0

            if let errorData = rpcError.data as? [String: Any],
               let timeInterval = errorData["backoff_seconds"] as? TimeInterval
            {
                backoffSeconds = timeInterval
            }

            completion(.retryWithDelay(backoffSeconds))
        } else {
            completion(.doNotRetry)
        }
    }
}

// MARK: - Errors

extension RpcApiProvider {
    enum RequestError: Error {
        case invalidResponse(jsonObject: Any)
    }
}
