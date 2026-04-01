import Alamofire
import Foundation
import HsToolKit

class RpcApiProvider {
    private let networkManager: NetworkManager
    private let urls: [URL]
    private let headers: HTTPHeaders
    private let logger: Logger?

    private let state = RpcState()

    init(networkManager: NetworkManager, urls: [URL], auth: String?, logger: Logger? = nil) {
        self.networkManager = networkManager
        self.urls = urls
        self.logger = logger

        var headers = HTTPHeaders()
        if let auth {
            headers.add(.authorization(username: "", password: auth))
        }
        self.headers = headers
    }

    /// Thread-safe state: round-robin URL selection, RPC ID counter, throttle delay.
    ///
    /// `acquireSlot()` is fully synchronous inside the actor — no suspension in critical
    /// section. The caller sleeps OUTSIDE the actor with the returned delay. This avoids
    /// the race condition where `Task.sleep` inside an actor releases isolation and lets
    /// other callers enter concurrently.
    private actor RpcState {
        private let minInterval: TimeInterval = 0.3
        private var nextRequestTime: TimeInterval = 0
        private var urlIndex = 0
        private var rpcId = 0

        /// Returns the next URL, a unique RPC ID, and the delay to wait before sending.
        func acquireSlot(urls: [URL]) -> (url: URL, rpcId: Int, delay: TimeInterval) {
            let now = Date().timeIntervalSince1970
            let delay = max(0, nextRequestTime - now)
            nextRequestTime = now + delay + minInterval

            let url = urls[urlIndex]
            urlIndex = (urlIndex + 1) % urls.count

            rpcId += 1
            return (url, rpcId, delay)
        }
    }

    /// Acquires a throttle slot, waits the required delay, returns URL and RPC ID.
    private func nextSlot() async -> (url: URL, rpcId: Int) {
        let (url, rpcId, delay) = await state.acquireSlot(urls: urls)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return (url, rpcId)
    }

    private func rpcResult<T>(rpc: JsonRpc<T>, attempt: Int = 0) async throws -> T {
        let (url, rpcId) = await nextSlot()

        do {
            let json = try await networkManager.fetchJson(
                url: url,
                method: .post,
                parameters: rpc.parameters(id: rpcId),
                encoding: JSONEncoding.default,
                headers: headers,
                interceptor: self,
                responseCacherBehavior: .doNotCache
            )

            guard let rpcResponse = JsonRpcResponse.response(jsonObject: json) else {
                throw RequestError.invalidResponse(jsonObject: json)
            }

            return try rpc.parse(response: rpcResponse)
        } catch {
            // Round-robin failover: try next URL, up to 2 full cycles.
            if attempt < urls.count * 2 {
                logger?.debug("RpcApiProvider: request failed (attempt \(attempt + 1), url: \(url.host ?? "?")), retrying: \(error)")
                return try await rpcResult(rpc: rpc, attempt: attempt + 1)
            }
            throw error
        }
    }
}

// MARK: - IRpcApiProvider

extension RpcApiProvider: IRpcApiProvider {
    var source: String {
        urls.first?.host ?? "unknown"
    }

    func fetch<T>(rpc: JsonRpc<T>) async throws -> T {
        try await rpcResult(rpc: rpc)
    }

    /// Sends a JSON-RPC batch request.
    ///
    /// Uses throttle + round-robin URL selection. No retry for batch — failure
    /// retries on the next sync heartbeat (30s).
    func fetchBatch<T>(rpcs: [JsonRpc<T>]) async throws -> [T?] {
        guard !rpcs.isEmpty else { return [] }

        let (url, _) = await nextSlot()

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
            else {
                logger?.warning("RpcApiProvider: batch — invalid id or structure: \(dict["id"] ?? "nil")")
                continue
            }

            do {
                results[id] = try rpcs[id].parse(response: rpcResponse)
            } catch {
                logger?.error("RpcApiProvider: batch parse failed for id \(id): \(error)")
            }
        }
        return results
    }
}

// MARK: - Batch Transaction Convenience

extension RpcApiProvider {
    /// Fetches multiple transactions by signature via batch RPC requests.
    ///
    /// Chunks signatures into groups of 100, issues one batch per chunk.
    func fetchTransactionsBatch(signatures: [String]) async throws -> [String: RpcTransactionResponse] {
        let batchChunkSize = 100
        var result: [String: RpcTransactionResponse] = [:]

        let chunks = signatures.chunked(into: batchChunkSize)
        for (chunkIndex, chunk) in chunks.enumerated() {
            let rpcs = chunk.map { GetTransactionJsonRpc(signature: $0) }
            let responses: [RpcTransactionResponse??] = try await fetchBatch(rpcs: rpcs)
            var chunkParsed = 0
            for (signature, maybeResponse) in zip(chunk, responses) {
                if let outerOpt = maybeResponse, let tx = outerOpt {
                    result[signature] = tx
                    chunkParsed += 1
                }
            }
        }

        return result
    }
}

// MARK: - Array chunk helper

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - RequestInterceptor (Alamofire retry for RPC -32005)

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
