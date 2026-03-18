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
