import Foundation

/// JSON-RPC call: `getMultipleAccounts`
///
/// Fetches raw account data for multiple addresses in a single RPC call.
/// Uses `base64` encoding; returns `nil` for accounts that do not exist.
///
/// Response shape: `{"context":{...},"value":[BufferInfo|null,...]}`
///
/// Used by `TokenAccountManager` to refresh token balances and by
/// `TransactionSyncer` to fetch `Mint` account data for decimals/supply.
class GetMultipleAccountsJsonRpc: JsonRpc<[BufferInfo?]> {
    init(addresses: [String]) {
        super.init(
            method: "getMultipleAccounts",
            params: [
                addresses,
                ["encoding": "base64"],
            ]
        )
    }

    override func parse(result: Any) throws -> [BufferInfo?] {
        guard
            let dict = result as? [String: Any],
            let value = dict["value"]
        else {
            throw JsonRpcResponse.ResponseError.invalidResult(value: result)
        }

        let data = try JSONSerialization.data(withJSONObject: value, options: [])
        return try JSONDecoder().decode([BufferInfo?].self, from: data)
    }
}
