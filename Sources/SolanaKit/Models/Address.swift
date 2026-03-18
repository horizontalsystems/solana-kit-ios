import Foundation
import GRDB

/// A Solana account address, wrapping a 32-byte Ed25519 `PublicKey`.
///
/// Use `Address` everywhere an account address is passed through the public API.
/// The canonical string form is Base58 (Solana standard).
public struct Address {
    /// The underlying 32-byte public key.
    public let publicKey: PublicKey

    /// Creates an `Address` directly from a `PublicKey`.
    public init(publicKey: PublicKey) {
        self.publicKey = publicKey
    }

    /// Creates an `Address` by decoding a Base58 string.
    /// - Throws: `PublicKey.Error` if the string is not valid Base58 or not 32 bytes.
    public init(_ base58String: String) throws {
        publicKey = try PublicKey(base58String)
    }

    /// The Base58-encoded string representation of this address.
    public var base58: String {
        publicKey.base58
    }
}

// MARK: - Equatable & Hashable

extension Address: Equatable {
    public static func == (lhs: Address, rhs: Address) -> Bool {
        lhs.publicKey == rhs.publicKey
    }
}

extension Address: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(publicKey)
    }
}

// MARK: - CustomStringConvertible

extension Address: CustomStringConvertible {
    public var description: String {
        base58
    }
}

// MARK: - DatabaseValueConvertible (GRDB)

extension Address: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        publicKey.databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Address? {
        PublicKey.fromDatabaseValue(dbValue).map { Address(publicKey: $0) }
    }
}

// MARK: - Codable

extension Address: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(PublicKey.self)
        self.init(publicKey: key)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(publicKey)
    }
}

// MARK: - ValidationError

public extension Address {
    /// Errors thrown during address validation or construction.
    enum ValidationError: Swift.Error {
        /// The provided string is not a valid Solana address.
        case invalidAddress
    }
}
