import Foundation

/// A keyed account entry returned by `getTokenAccountsByOwner` with `jsonParsed` encoding.
///
/// Response shape per element:
/// ```json
/// {
///   "pubkey": "<token-account-address>",
///   "account": {
///     "data": {
///       "parsed": {
///         "info": {
///           "mint": "<mint-address>",
///           "owner": "<wallet-address>",
///           "tokenAmount": { "amount": "...", "decimals": 6, "uiAmountString": "..." }
///         },
///         "type": "account"
///       },
///       "program": "spl-token",
///       "space": 165
///     },
///     "executable": false,
///     "lamports": 2039280,
///     "owner": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
///     "rentEpoch": 0
///   }
/// }
/// ```
struct RpcKeyedAccount: Decodable {
    let pubkey: String
    let account: RpcParsedAccountInfo
}

struct RpcParsedAccountInfo: Decodable {
    let data: RpcTokenAccountData
}

struct RpcTokenAccountData: Decodable {
    let parsed: RpcTokenAccountParsed
}

struct RpcTokenAccountParsed: Decodable {
    let info: RpcTokenAccountInfo
}

struct RpcTokenAccountInfo: Decodable {
    let mint: String
    let owner: String
    /// Raw token amount (uses `RpcUiTokenAmount` defined in `RpcTransactionResponse.swift`).
    let tokenAmount: RpcUiTokenAmount
}
