import Foundation

/// JSON-RPC call: `getTransaction`
///
/// Fetches a confirmed transaction by signature. Returns `nil` when the transaction
/// is not found (e.g. pruned from the node's history).
///
/// Uses `jsonParsed` encoding and supports versioned transactions
/// (`maxSupportedTransactionVersion: 0`), matching Android's batch request params.
class GetTransactionJsonRpc: JsonRpc<RpcTransactionResponse?> {
    init(signature: String) {
        super.init(
            method: "getTransaction",
            params: [
                signature,
                [
                    "encoding": "jsonParsed",
                    "maxSupportedTransactionVersion": 0,
                ],
            ]
        )
    }

    override func parse(result: Any) throws -> RpcTransactionResponse? {
        let data = try JSONSerialization.data(withJSONObject: result, options: [])
        return try JSONDecoder().decode(RpcTransactionResponse.self, from: data)
    }
}
