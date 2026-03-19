# Patch: Signer & Key Derivation — Review 1

**Source review:** `.ai-factory/reviews/19-4-2-signer-key-derivation-review-1.md`
**Files modified:** 1

---

## Fix 1: Add underlying error context to `SignError` cases

**File:** `Sources/SolanaKit/Core/Signer.swift`
**Lines:** 115-120 (error enum), 44-46 (sign catch), 62-66 (deriveKeyPair catch)
**Problem:** `SignError.invalidSeed` and `.signingFailed` discard the underlying library error. In production, crash reporters and logs show only the bare enum case with no detail about which step failed (HDWallet init, privateKey derivation, or NaCl keypair expansion). This makes debugging key derivation failures nearly impossible without reproduction steps.

### Step 1: Update the `SignError` enum to carry the underlying error

**Replace** (lines 115-120):
```swift
    enum SignError: Error {
        /// Thrown when HdWalletKit BIP44 derivation fails (e.g. invalid seed).
        case invalidSeed
        /// Thrown when the TweetNaCl Ed25519 signing operation fails.
        case signingFailed
    }
```

**With:**
```swift
    enum SignError: Error {
        /// Thrown when HdWalletKit BIP44 derivation fails (e.g. invalid seed).
        case invalidSeed(underlying: Error)
        /// Thrown when the TweetNaCl Ed25519 signing operation fails.
        case signingFailed(underlying: Error)
    }
```

### Step 2: Pass the caught error through in `sign(data:)`

**Replace** (lines 44-46):
```swift
        } catch {
            throw SignError.signingFailed
        }
```

**With:**
```swift
        } catch {
            throw SignError.signingFailed(underlying: error)
        }
```

### Step 3: Pass the caught error through in `deriveKeyPair(seed:)`

**Replace** (lines 62-66):
```swift
        } catch let error as SignError {
            throw error
        } catch {
            throw SignError.invalidSeed
        }
```

**With:**
```swift
        } catch {
            throw SignError.invalidSeed(underlying: error)
        }
```

This also removes the dead `catch let error as SignError` branch (Fix 2 below), since with associated values the rethrow pattern no longer applies.

---

## Fix 2: Remove dead `catch` branch in `deriveKeyPair`

**File:** `Sources/SolanaKit/Core/Signer.swift`
**Lines:** 62-63
**Problem:** The `catch let error as SignError { throw error }` branch is unreachable. No code inside the `do` block throws a `SignError` — the only throwing calls are `hdWallet.privateKey(account:)` (throws HDWalletKit errors) and `NaclSign.KeyPair.keyPair(fromSeed:)` (throws `NaclSignError`). The dead branch is confusing for future readers.

**Fix:** Already covered by Fix 1 Step 3 above — the two-branch catch is replaced with a single generic `catch` that passes the underlying error through.

---

## Resulting file after all fixes

After applying both fixes, the full `Sources/SolanaKit/Core/Signer.swift` should read:

```swift
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
            throw SignError.signingFailed(underlying: error)
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
        } catch {
            throw SignError.invalidSeed(underlying: error)
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
        case invalidSeed(underlying: Error)
        /// Thrown when the TweetNaCl Ed25519 signing operation fails.
        case signingFailed(underlying: Error)
    }
}
```

---

## Callsite impact

Callers that pattern-match on `SignError` cases need updating. The only known callsite is in `unstoppable-wallet-ios/Core/Managers/SolanaKitManager.swift`, which calls `Signer.address(seed:)` and `Signer.instance(seed:)` but catches errors generically (no `switch` on `SignError` cases), so **no callsite changes are required**.

Any future `switch` on `SignError` will naturally destructure the associated value:
```swift
catch let error as Signer.SignError {
    switch error {
    case .invalidSeed(let underlying):
        logger.error("Seed derivation failed: \(underlying)")
    case .signingFailed(let underlying):
        logger.error("Signing failed: \(underlying)")
    }
}
```
