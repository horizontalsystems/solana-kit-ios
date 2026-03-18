import Foundation

/// JSON-RPC call: `getBalance`
///
/// Returns the SOL balance in lamports for the given address.
/// Response shape: `{"context":{"slot":...},"value":<lamports>}`
class GetBalanceJsonRpc: JsonRpc<Int64> {
    init(address: String) {
        super.init(
            method: "getBalance",
            params: [address, ["commitment": "confirmed"]]
        )
    }

    override func parse(result: Any) throws -> Int64 {
        guard
            let dict = result as? [String: Any],
            let value = dict["value"]
        else {
            throw JsonRpcResponse.ResponseError.invalidResult(value: result)
        }

        if let number = value as? NSNumber {
            return number.int64Value
        }

        throw JsonRpcResponse.ResponseError.invalidResult(value: result)
    }
}
