import Foundation

public enum JsonRpcResponse {
    case success(SuccessResponse)
    case error(ErrorResponse)

    var id: Int {
        switch self {
        case let .success(response):
            return response.id
        case let .error(response):
            return response.id
        }
    }

    static func response(jsonObject: Any) -> JsonRpcResponse? {
        if let successResponse = SuccessResponse(jsonObject: jsonObject) {
            return .success(successResponse)
        }

        if let errorResponse = ErrorResponse(jsonObject: jsonObject) {
            return .error(errorResponse)
        }

        return nil
    }
}

public extension JsonRpcResponse {
    struct SuccessResponse {
        let id: Int
        var result: Any?

        init?(jsonObject: Any) {
            guard
                let dict = jsonObject as? [String: Any],
                dict["jsonrpc"] != nil,
                let id = dict["id"] as? Int,
                dict.keys.contains("result")
            else {
                return nil
            }

            self.id = id

            let rawResult = dict["result"]
            if rawResult == nil || rawResult is NSNull {
                self.result = nil
            } else {
                self.result = rawResult
            }
        }
    }

    struct ErrorResponse {
        let id: Int
        let error: RpcError

        init?(jsonObject: Any) {
            guard
                let dict = jsonObject as? [String: Any],
                let id = dict["id"] as? Int,
                let errorDict = dict["error"] as? [String: Any],
                let rpcError = RpcError(dict: errorDict)
            else {
                return nil
            }

            self.id = id
            self.error = rpcError
        }
    }

    struct RpcError {
        public let code: Int
        public let message: String
        public let data: Any?

        init?(dict: [String: Any]) {
            guard
                let code = dict["code"] as? Int,
                let message = dict["message"] as? String
            else {
                return nil
            }

            self.code = code
            self.message = message
            self.data = dict["data"]
        }
    }

    enum ResponseError: Error {
        case rpcError(JsonRpcResponse.RpcError)
        case invalidResult(value: Any?)
    }
}
