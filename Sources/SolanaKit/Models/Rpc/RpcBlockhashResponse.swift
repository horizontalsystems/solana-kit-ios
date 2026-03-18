import Foundation

/// The `value` object returned by `getLatestBlockhash`.
struct RpcBlockhashResponse: Decodable {
    let blockhash: String
    let lastValidBlockHeight: Int64
}

/// RPC slot context included in many responses.
struct RpcContext: Decodable {
    let slot: Int64
}

/// Generic wrapper for RPC responses of the form `{"context":{...},"value":<T>}`.
///
/// Reused by `getBalance`, `getTokenAccountsByOwner`, and `getLatestBlockhash`.
struct RpcResultResponse<T: Decodable>: Decodable {
    let context: RpcContext?
    let value: T
}
