import Foundation

// MARK: - AnyCodable

/// Lightweight wrapper for JSON fields that may be any JSON value
/// (object, array, string, number, boolean).
///
/// Used exclusively for the `err` field in RPC responses, which is
/// only inspected for presence (`!= nil`) or converted to a debug string.
struct AnyCodable: Decodable, CustomStringConvertible {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else {
            value = ()
        }
    }

    var description: String {
        "\(value)"
    }
}

// MARK: - Top-level Transaction Response

/// Top-level response from `getTransaction` (jsonParsed encoding).
struct RpcTransactionResponse: Decodable {
    let blockTime: Int64?
    let meta: RpcTransactionMeta?
    let slot: Int64?
    let transaction: RpcTransactionDetail?
}

// MARK: - Transaction Meta

/// Transaction metadata (fees, balances, status).
struct RpcTransactionMeta: Decodable {
    /// Non-nil when the transaction failed; the value describes the error.
    let err: AnyCodable?
    let fee: Int64
    let preBalances: [Int64]
    let postBalances: [Int64]
    let preTokenBalances: [RpcTokenBalance]?
    let postTokenBalances: [RpcTokenBalance]?
}

// MARK: - Token Balance

/// SPL token balance entry inside transaction meta.
struct RpcTokenBalance: Decodable {
    let accountIndex: Int
    let mint: String
    let owner: String?
    let uiTokenAmount: RpcUiTokenAmount?
}

/// Human-readable token amount, as returned by `uiTokenAmount` / `tokenAmount` fields.
struct RpcUiTokenAmount: Decodable {
    let amount: String
    let decimals: Int
    let uiAmountString: String?
}

// MARK: - Transaction Detail

/// The `transaction` object inside a `getTransaction` response (jsonParsed).
struct RpcTransactionDetail: Decodable {
    let message: RpcTransactionMessage?
}

/// The `message` inside `transaction` — contains the list of account keys.
struct RpcTransactionMessage: Decodable {
    let accountKeys: [RpcAccountKey]?
}

/// A single account key entry in a transaction message (jsonParsed format).
struct RpcAccountKey: Decodable {
    let pubkey: String
    let signer: Bool?
    let writable: Bool?
}
