import Foundation

/// JSON-RPC call: `getSignaturesForAddress`
///
/// Returns a list of confirmed signatures for transactions involving the given address,
/// newest first. Supports pagination via `before` (exclusive) and `until` (inclusive)
/// cursors, plus a `limit` cap.
///
/// Mirrors Android's `ConfirmedSignFAddr2(limit, before, until)` request params.
class GetSignaturesForAddressJsonRpc: JsonRpc<[SignatureInfo]> {
    init(address: String, limit: Int? = nil, before: String? = nil, until: String? = nil) {
        var config: [String: Any] = [:]
        if let limit { config["limit"] = limit }
        if let before { config["before"] = before }
        if let until { config["until"] = until }

        let params: [Any] = config.isEmpty ? [address] : [address, config]

        super.init(method: "getSignaturesForAddress", params: params)
    }

    override func parse(result: Any) throws -> [SignatureInfo] {
        let data = try JSONSerialization.data(withJSONObject: result, options: [])
        return try JSONDecoder().decode([SignatureInfo].self, from: data)
    }
}
