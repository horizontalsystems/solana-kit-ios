import Foundation

/// JSON-RPC call: `sendTransaction`
///
/// Broadcasts a signed, serialized transaction to the network.
/// Returns the transaction signature string on success.
///
/// Params match Android's `PendingTransactionSyncer.sendTransaction` call:
/// - `encoding: "base64"` — the transaction is base64-encoded
/// - `skipPreflight: false` — validate before sending
/// - `preflightCommitment: "confirmed"`
/// - `maxRetries: 0` — no automatic node-level retries (we handle retries)
class SendTransactionJsonRpc: JsonRpc<String> {
    init(base64EncodedTransaction: String) {
        super.init(
            method: "sendTransaction",
            params: [
                base64EncodedTransaction,
                [
                    "encoding": "base64",
                    "skipPreflight": false,
                    "preflightCommitment": "confirmed",
                    "maxRetries": 0,
                ],
            ]
        )
    }

    override func parse(result: Any) throws -> String {
        guard let signature = result as? String else {
            throw JsonRpcResponse.ResponseError.invalidResult(value: result)
        }
        return signature
    }
}
