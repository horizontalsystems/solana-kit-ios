import Foundation

/// JSON-RPC call: `getLatestBlockhash`
///
/// Returns the most recent blockhash and its last valid block height.
/// Used when building transactions that require a fresh blockhash.
///
/// Mirrors Android's `connection.getLatestBlockhashExtended(Commitment.FINALIZED)`.
/// Response shape: `{"context":{...},"value":{"blockhash":"...","lastValidBlockHeight":...}}`
class GetLatestBlockhashJsonRpc: JsonRpc<RpcBlockhashResponse> {
    init() {
        super.init(
            method: "getLatestBlockhash",
            params: [["commitment": "finalized"]]
        )
    }

    override func parse(result: Any) throws -> RpcBlockhashResponse {
        guard
            let dict = result as? [String: Any],
            let value = dict["value"]
        else {
            throw JsonRpcResponse.ResponseError.invalidResult(value: result)
        }

        let data = try JSONSerialization.data(withJSONObject: value, options: [])
        return try JSONDecoder().decode(RpcBlockhashResponse.self, from: data)
    }
}
