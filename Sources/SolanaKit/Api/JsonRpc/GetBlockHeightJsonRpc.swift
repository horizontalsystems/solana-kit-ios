import Foundation

/// JSON-RPC call: `getBlockHeight`
///
/// Returns the current block height (slot) as a bare integer.
class GetBlockHeightJsonRpc: JsonRpc<Int64> {
    init() {
        super.init(method: "getBlockHeight")
    }

    override func parse(result: Any) throws -> Int64 {
        if let number = result as? NSNumber {
            return number.int64Value
        }

        throw JsonRpcResponse.ResponseError.invalidResult(value: result)
    }
}
