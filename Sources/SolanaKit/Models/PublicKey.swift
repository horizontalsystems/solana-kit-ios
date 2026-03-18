import CryptoKit
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
    static let systemProgramId                  = try! PublicKey("11111111111111111111111111111111")
    static let tokenProgramId                   = try! PublicKey("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")
    static let associatedTokenProgramId         = try! PublicKey("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")
    static let sysvarRentProgramId              = try! PublicKey("SysvarRent111111111111111111111111111111111")
    static let computeBudgetProgramId           = try! PublicKey("ComputeBudget111111111111111111111111111111")
    static let metaplexTokenMetadataProgramId   = try! PublicKey("metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s")
    // swiftlint:enable force_try
}

// MARK: - Program Derived Address (PDA)

extension PublicKey {

    /// Derives the Metaplex Metadata PDA for the given mint.
    ///
    /// Seeds: ["metadata", metaplexTokenMetadataProgramId.bytes, mintPublicKey.bytes]
    /// Matches Android's `MetadataAccount.pda(mintKey)`.
    static func metadataPDA(mintPublicKey: PublicKey) throws -> PublicKey {
        let seeds: [Data] = [
            Data("metadata".utf8),
            metaplexTokenMetadataProgramId.data,
            mintPublicKey.data,
        ]
        let (pda, _) = try findProgramAddress(seeds: seeds, programId: metaplexTokenMetadataProgramId)
        return pda
    }

    /// Finds the canonical program-derived address by iterating bump seeds 255 → 0.
    ///
    /// Returns the first (address, bump) pair whose hash is **not** on the Ed25519 curve,
    /// matching Solana's `PublicKey.findProgramAddress` specification.
    static func findProgramAddress(seeds: [Data], programId: PublicKey) throws -> (PublicKey, UInt8) {
        var bump = UInt8(255)
        while true {
            let seedsWithBump = seeds + [Data([bump])]
            if let address = try? createProgramAddress(seeds: seedsWithBump, programId: programId) {
                return (address, bump)
            }
            if bump == 0 { break }
            bump -= 1
        }
        throw PDAError.couldNotFindValidAddress
    }

    /// Computes one candidate program-derived address.
    ///
    /// Throws `PDAError.invalidSeeds` when the resulting SHA-256 hash falls on the Ed25519 curve
    /// (i.e., it is a valid public key — not suitable as a PDA).
    static func createProgramAddress(seeds: [Data], programId: PublicKey) throws -> PublicKey {
        var hashInput = Data()
        for seed in seeds {
            guard seed.count <= 32 else { throw PDAError.maxSeedLengthExceeded }
            hashInput.append(seed)
        }
        hashInput.append(programId.data)
        hashInput.append(Data("ProgramDerivedAddress".utf8))

        let hashBytes = Data(SHA256.hash(data: hashInput))

        guard !isOnEd25519Curve(hashBytes) else {
            throw PDAError.invalidSeeds
        }

        return try PublicKey(data: hashBytes)
    }

    /// Returns `true` when `bytes` encodes a valid compressed Ed25519 point.
    ///
    /// `Curve25519.Signing.PublicKey(rawRepresentation:)` calls BoringSSL's
    /// `ED25519_check_public_key`, which decompresses the Edwards25519 point and
    /// validates it is on the curve. It throws for invalid points, not only for
    /// wrong-length inputs. Verified against the known Metaplex metadata PDA for
    /// the USDC mint (`EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v`), which
    /// correctly derives to `2uMBJkes3jHP73XNFQ5iKiX3MoDaKo5RsYfLjETyDox`.
    private static func isOnEd25519Curve(_ bytes: Data) -> Bool {
        guard bytes.count == 32 else { return false }
        return (try? Curve25519.Signing.PublicKey(rawRepresentation: bytes)) != nil
    }

    enum PDAError: Swift.Error {
        case maxSeedLengthExceeded
        case invalidSeeds
        case couldNotFindValidAddress
    }
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
