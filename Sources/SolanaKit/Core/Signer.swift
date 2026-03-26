import CryptoKit
import Foundation
import HdWalletKit
import HsCryptoKit

public class Signer {
    private let signingKey: Curve25519.Signing.PrivateKey

    init(signingKey: Curve25519.Signing.PrivateKey) {
        self.signingKey = signingKey
    }

    public var address: Address {
        // swiftlint:disable:next force_try
        let key = try! PublicKey(data: signingKey.publicKey.rawRepresentation)
        return Address(publicKey: key)
    }

    public func sign(data: Data) throws -> Data {
        do {
            return try Data(signingKey.signature(for: data))
        } catch {
            throw SignError.signingFailed(underlying: error)
        }
    }

    private static func deriveSigningKey(seed: Data, coinType: UInt32 = 501, xPrivKey: UInt32 = 0, purpose: Purpose = .bip44, curve: DerivationCurve = .ed25519) throws -> Curve25519.Signing.PrivateKey {
        do {
            let hdWallet = HDWallet(seed: seed, coinType: coinType, xPrivKey: xPrivKey, purpose: purpose, curve: curve)
            let key = try hdWallet.privateKey(path: "m/\(purpose.rawValue)'/\(coinType)'/0'/0'")
            return try Curve25519.Signing.PrivateKey(rawRepresentation: key.raw)
        } catch {
            throw SignError.invalidSeed(underlying: error)
        }
    }
}

public extension Signer {
    static func instance(seed: Data, coinType: UInt32 = 501, xPrivKey: UInt32 = 0, purpose: Purpose = .bip44, curve: DerivationCurve = .ed25519) throws -> Signer {
        let signingKey = try deriveSigningKey(seed: seed, coinType: coinType, xPrivKey: xPrivKey, purpose: purpose, curve: curve)
        return Signer(signingKey: signingKey)
    }

    static func address(seed: Data, coinType: UInt32 = 501, xPrivKey: UInt32 = 0, purpose: Purpose = .bip44, curve: DerivationCurve = .ed25519) throws -> Address {
        let signingKey = try deriveSigningKey(seed: seed, coinType: coinType, xPrivKey: xPrivKey, purpose: purpose, curve: curve)
        // swiftlint:disable:next force_try
        let key = try! PublicKey(data: signingKey.publicKey.rawRepresentation)
        return Address(publicKey: key)
    }

    static func privateKey(seed: Data, coinType: UInt32 = 501, xPrivKey: UInt32 = 0, purpose: Purpose = .bip44, curve: DerivationCurve = .ed25519) throws -> Data {
        let signingKey = try deriveSigningKey(seed: seed, coinType: coinType, xPrivKey: xPrivKey, purpose: purpose, curve: curve)
        return signingKey.rawRepresentation
    }
}

public extension Signer {
    enum SignError: Error {
        case invalidSeed(underlying: Error)
        case signingFailed(underlying: Error)
    }
}
