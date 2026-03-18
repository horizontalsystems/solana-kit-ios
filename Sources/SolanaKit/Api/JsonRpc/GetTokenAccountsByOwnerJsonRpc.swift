import Foundation

/// JSON-RPC call: `getTokenAccountsByOwner`
///
/// Returns all SPL token accounts owned by the given wallet address.
/// Uses `jsonParsed` encoding so account data is decoded server-side.
///
/// Response shape: `{"context":{...},"value":[RpcKeyedAccount,...]}`
class GetTokenAccountsByOwnerJsonRpc: JsonRpc<[RpcKeyedAccount]> {
    init(ownerAddress: String) {
        super.init(
            method: "getTokenAccountsByOwner",
            params: [
                ownerAddress,
                ["programId": TokenProgram.programId],
                ["encoding": "jsonParsed"],
            ]
        )
    }

    override func parse(result: Any) throws -> [RpcKeyedAccount] {
        guard
            let dict = result as? [String: Any],
            let value = dict["value"]
        else {
            throw JsonRpcResponse.ResponseError.invalidResult(value: result)
        }

        let data = try JSONSerialization.data(withJSONObject: value, options: [])
        return try JSONDecoder().decode([RpcKeyedAccount].self, from: data)
    }
}
