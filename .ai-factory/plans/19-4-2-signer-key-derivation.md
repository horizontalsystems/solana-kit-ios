# Plan: Signer & Key Derivation

## Context

Create `Signer.swift` — a standalone public class that derives an Ed25519 keypair from a BIP39 mnemonic seed via HdWalletKit.Swift (BIP44 path `m/44'/501'/0'`, curve `.ed25519`) and signs arbitrary data using TweetNaCl's Ed25519 detached signatures. `Signer` is intentionally decoupled from `Kit` — it holds key material that `Kit` never touches.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Signer Implementation

- [x] **Task 1: Create `Signer.swift` — class skeleton with key derivation**
  Files: `Sources/SolanaKit/Core/Signer.swift`
  Create `Signer.swift` in `Core/` as a `public class`. Follow the EvmKit `Signer.swift` pattern (`/EvmKit.Swift/Sources/EvmKit/Core/Signer/Signer.swift`):
  - `internal init` (never instantiated directly — only via static factories)
  - Store two private properties: `publicKey: Data` (32 bytes) and `secretKey: Data` (64 bytes, NaCl format: seed || pubkey)
  - Expose `public let address: Address` computed from the 32-byte public key via existing `PublicKey(data:)` → `Address(publicKey:)`
  - Import `HdWalletKit` and `TweetNacl`
  - Implement the core private derivation helper `deriveKeyPair(seed:)` as a private static method:
    1. `HDWallet(seed: seed, coinType: 501, xPrivKey: 0, curve: .ed25519)` — use `xPrivKey: 0` (not `xprv.rawValue`), matching `TonKitManager.swift` line 182 exactly
    2. `try hdWallet.privateKey(account: 0)` — produces path `m/44'/501'/0'` (three hardened components, matching Android's `DerivableType.BIP44CHANGE`)
    3. `Data(privateKey.raw.bytes)` — extract 32-byte raw Ed25519 seed
    4. `try NaclSign.KeyPair.keyPair(fromSeed: privateRaw)` — expand to NaCl keypair `(publicKey: Data, secretKey: Data)`

- [x] **Task 2: Add static factory methods**
  Files: `Sources/SolanaKit/Core/Signer.swift`
  Add a `public extension Signer` block (matching EvmKit's pattern) with three static methods:
  - `static func instance(seed: Data) throws -> Signer` — derives keypair via `deriveKeyPair`, creates `Signer` with the result. This is the primary factory (called from `SolanaKitManager` in the wallet app).
  - `static func address(seed: Data) throws -> Address` — derives keypair, returns only the `Address` (32-byte public key wrapped in `PublicKey` → `Address`). Used by the wallet to show the receive address without creating a full `Signer`. Matches Android's `Signer.address(seed)`.
  - `static func privateKey(seed: Data) throws -> Data` — derives keypair, returns the 64-byte NaCl secret key. Matches Android's `Signer.privateKey(seed)`. Useful for callers that need the raw key (e.g., WalletConnect signing).

- [x] **Task 3: Add Ed25519 signing method and error type**
  Files: `Sources/SolanaKit/Core/Signer.swift`
  Add to the `Signer` class:
  - `public func sign(data: Data) throws -> Data` — calls `NaclSign.signDetached(message: data, secretKey: secretKey)` and returns the 64-byte Ed25519 detached signature. This is the method that transaction serialization (milestone 4.3) will call to sign the serialized transaction message bytes.
  - Add a `public extension Signer` block with `enum SignError: Error` containing:
    - `case invalidSeed` — thrown when HdWalletKit derivation fails (wraps the underlying error)
    - `case signingFailed` — thrown when TweetNaCl signing fails (wraps the underlying error)
  - Wrap the `HDWallet` and `NaclSign` calls in the derivation helper and signing method with do/catch that rethrow as the appropriate `SignError` cases, so callers get a clean SolanaKit error type rather than raw HdWalletKit/TweetNaCl errors.
