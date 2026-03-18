import Foundation
import GRDB

/// A 32-byte Solana public key (Ed25519).
///
/// The canonical string representation is Base58.
/// `Codable` encodes/decodes as a Base58 string, matching the Solana JSON-RPC format.
/// `DatabaseValueConvertible` stores the raw 32 bytes as a GRDB blob.
public struct PublicKey {
    /// The raw 32-byte public key.
    public let data: Data

    // MARK: - Initializers

    /// Creates a `PublicKey` from raw bytes. Throws if `data.count != 32`.
    public init(data: Data) throws {
        guard data.count == 32 else {
            throw Error.invalidPublicKeyLength
        }
        self.data = data
    }

    /// Creates a `PublicKey` by decoding a Base58 string. Throws on invalid Base58 or wrong length.
    public init(_ base58String: String) throws {
        do {
            let decoded = try Base58.decode(base58String)
            try self.init(data: decoded)
        } catch Base58.Error.invalidCharacter {
            throw Error.invalidBase58String
        }
    }

    // MARK: - Properties

    /// The Base58-encoded string representation of this public key.
    public var base58: String {
        Base58.encode(data)
    }

    /// The raw bytes of this public key (alias for `data`).
    public var bytes: Data {
        data
    }
}

// MARK: - Well-known program IDs

extension PublicKey {
    // swiftlint:disable force_try
    static let systemProgramId             = try! PublicKey("11111111111111111111111111111111")
    static let tokenProgramId              = try! PublicKey("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")
    static let associatedTokenProgramId    = try! PublicKey("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")
    static let sysvarRentProgramId         = try! PublicKey("SysvarRent111111111111111111111111111111111")
    static let computeBudgetProgramId      = try! PublicKey("ComputeBudget111111111111111111111111111111")
    // swiftlint:enable force_try
}

// MARK: - Error

extension PublicKey {
    public enum Error: Swift.Error {
        case invalidPublicKeyLength
        case invalidBase58String
    }
}

// MARK: - Equatable & Hashable

extension PublicKey: Equatable {
    public static func == (lhs: PublicKey, rhs: PublicKey) -> Bool {
        lhs.data == rhs.data
    }
}

extension PublicKey: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(data)
    }
}

// MARK: - CustomStringConvertible

extension PublicKey: CustomStringConvertible {
    public var description: String {
        base58
    }
}

// MARK: - DatabaseValueConvertible (GRDB)

extension PublicKey: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        data.databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> PublicKey? {
        switch dbValue.storage {
        case let .blob(data):
            return try? PublicKey(data: data)
        default:
            return nil
        }
    }
}

// MARK: - Codable

extension PublicKey: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        do {
            try self.init(string)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Base58 public key: \(string)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base58)
    }
}
