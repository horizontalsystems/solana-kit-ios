import Foundation
import HdWalletKit
import TweetNacl

/// Derives an Ed25519 keypair from a BIP39 mnemonic seed and signs data.
///
/// `Signer` is intentionally decoupled from `Kit` — it holds key material that `Kit` never touches.
/// Callers create a `Signer` from a mnemonic seed, sign a transaction, then pass the serialised
/// signed bytes to `kit.send(signedTransaction:)`.
///
/// BIP44 derivation path: `m/44'/501'/0'` (coin type 501, hardened account 0).
public class Signer {
    private let publicKey: Data   // 32 bytes — raw Ed25519 public key
    private let secretKey: Data   // 64 bytes — NaCl format: seed || pubkey

    // MARK: - Init (internal — use static factory methods)

    init(publicKey: Data, secretKey: Data) {
        self.publicKey = publicKey
        self.secretKey = secretKey
    }

    // MARK: - Public properties

    /// The Solana address derived from the Ed25519 public key.
    public var address: Address {
        // PublicKey(data:) throws only when data.count != 32.
        // Our publicKey is always exactly 32 bytes (guaranteed by NaclSign.KeyPair).
        // swiftlint:disable:next force_try
        let key = try! PublicKey(data: publicKey)
        return Address(publicKey: key)
    }

    // MARK: - Signing

    /// Signs `data` using Ed25519 and returns the 64-byte detached signature.
    ///
    /// - Parameter data: The serialised transaction message bytes to sign.
    /// - Returns: A 64-byte Ed25519 detached signature.
    /// - Throws: `SignError.signingFailed` if the NaCl signing operation fails.
    public func sign(data: Data) throws -> Data {
        do {
            return try NaclSign.signDetached(message: data, secretKey: secretKey)
        } catch {
            throw SignError.signingFailed
        }
    }

    // MARK: - Private helpers

    /// Derives an Ed25519 keypair from the given BIP39 seed using path `m/44'/501'/0'`.
    ///
    /// - Parameter seed: The BIP39 master seed (64 bytes from mnemonic).
    /// - Returns: A tuple of `(publicKey: Data, secretKey: Data)` — both in NaCl format.
    /// - Throws: `SignError.invalidSeed` if HdWalletKit derivation fails.
    private static func deriveKeyPair(seed: Data) throws -> (publicKey: Data, secretKey: Data) {
        do {
            let hdWallet = HDWallet(seed: seed, coinType: 501, xPrivKey: 0, curve: .ed25519)
            let privateKey = try hdWallet.privateKey(account: 0)  // path: m/44'/501'/0'
            let privateRaw = privateKey.raw                        // 32-byte Ed25519 seed
            return try NaclSign.KeyPair.keyPair(fromSeed: privateRaw)
        } catch let error as SignError {
            throw error
        } catch {
            throw SignError.invalidSeed
        }
    }
}

// MARK: - Static factory methods

public extension Signer {
    /// Creates a `Signer` by deriving the Ed25519 keypair from a BIP39 seed.
    ///
    /// This is the primary factory, called from `SolanaKitManager` in the wallet app.
    ///
    /// - Parameter seed: The BIP39 master seed.
    /// - Throws: `SignError.invalidSeed` if key derivation fails.
    static func instance(seed: Data) throws -> Signer {
        let keypair = try deriveKeyPair(seed: seed)
        return Signer(publicKey: keypair.publicKey, secretKey: keypair.secretKey)
    }

    /// Derives the Solana `Address` from a BIP39 seed without creating a full `Signer`.
    ///
    /// Used by the wallet to show the receive address before a `Signer` is needed.
    /// Matches Android's `Signer.address(seed)`.
    ///
    /// - Parameter seed: The BIP39 master seed.
    /// - Throws: `SignError.invalidSeed` if key derivation fails.
    static func address(seed: Data) throws -> Address {
        let keypair = try deriveKeyPair(seed: seed)
        // swiftlint:disable:next force_try
        let key = try! PublicKey(data: keypair.publicKey)
        return Address(publicKey: key)
    }

    /// Returns the 64-byte NaCl secret key derived from a BIP39 seed.
    ///
    /// Useful for callers that need the raw key (e.g., WalletConnect signing).
    /// Matches Android's `Signer.privateKey(seed)`.
    ///
    /// - Parameter seed: The BIP39 master seed.
    /// - Throws: `SignError.invalidSeed` if key derivation fails.
    static func privateKey(seed: Data) throws -> Data {
        let keypair = try deriveKeyPair(seed: seed)
        return keypair.secretKey
    }
}

// MARK: - Error types

public extension Signer {
    /// Errors thrown by `Signer` key derivation and signing operations.
    enum SignError: Error {
        /// Thrown when HdWalletKit BIP44 derivation fails (e.g. invalid seed).
        case invalidSeed
        /// Thrown when the TweetNaCl Ed25519 signing operation fails.
        case signingFailed
    }
}
