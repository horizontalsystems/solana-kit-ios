import Foundation

/// Represents a Solana account's raw on-chain data as returned by the JSON-RPC
/// `getAccountInfo` and `getMultipleAccounts` methods.
///
/// The RPC response shape is:
/// ```json
/// {
///   "data": ["<base64-encoded-bytes>", "base64"],
///   "lamports": 1000000,
///   "owner": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
///   "executable": false,
///   "rentEpoch": 18446744073709551615,
///   "space": 165
/// }
/// ```
///
/// The `data` field is a 2-element JSON array `[base64String, encodingName]`.
/// Android handles this with `BufferInfoJsonAdapter` + Moshi; here we use a
/// custom `Decodable` initializer.
struct BufferInfo: Decodable {
    /// Raw account data bytes decoded from the base64 string.
    let data: Data

    /// Account balance in lamports.
    let lamports: UInt64

    /// Base58-encoded address of the program that owns this account.
    let owner: String

    /// Whether this account contains a program (and is strictly read-only).
    let executable: Bool

    /// The epoch at which this account will next owe rent.
    /// Solana encodes large values (up to 2^64-1) that exceed `Int64.max`,
    /// so we store as `UInt64`. Android worked around this via `toULong().toLong()`.
    let rentEpoch: UInt64

    /// The number of data bytes in the account (present in newer RPC versions).
    let space: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Decode the data field: ["<base64-string>", "base64"]
        var dataArray = try container.nestedUnkeyedContainer(forKey: .data)
        let base64String = try dataArray.decode(String.self)
        let encoding = try dataArray.decode(String.self)

        guard encoding == "base64" else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.data],
                    debugDescription: "Unsupported account data encoding '\(encoding)'; expected 'base64'"
                )
            )
        }

        guard let decoded = Data(base64Encoded: base64String) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath + [CodingKeys.data],
                    debugDescription: "Account data is not valid base64"
                )
            )
        }

        data = decoded
        lamports = try container.decode(UInt64.self, forKey: .lamports)
        owner = try container.decode(String.self, forKey: .owner)
        executable = try container.decode(Bool.self, forKey: .executable)

        // rentEpoch: try UInt64 directly first; fall back to String → UInt64.
        // Solana's modern rent epoch value (u64::MAX = 18446744073709551615) exceeds
        // JSON number precision in some implementations and may arrive as a string.
        if let value = try? container.decode(UInt64.self, forKey: .rentEpoch) {
            rentEpoch = value
        } else {
            let stringValue = try container.decode(String.self, forKey: .rentEpoch)
            guard let parsed = UInt64(stringValue) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath + [CodingKeys.rentEpoch],
                        debugDescription: "rentEpoch string '\(stringValue)' is not a valid UInt64"
                    )
                )
            }
            rentEpoch = parsed
        }

        space = try container.decodeIfPresent(Int.self, forKey: .space)
    }

    private enum CodingKeys: String, CodingKey {
        case data, lamports, owner, executable, rentEpoch, space
    }
}
