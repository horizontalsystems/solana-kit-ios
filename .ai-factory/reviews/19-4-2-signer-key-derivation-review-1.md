## Code Review Summary

**Files Reviewed:** 1 (`Sources/SolanaKit/Core/Signer.swift`)
**Risk Level:** 🟢 Low

### Context Gates

- **ARCHITECTURE.md:** PASS — `Signer` is correctly placed in `Core/`, is `public` (one of the two allowed public types alongside `Kit`), has no dependency on `Kit` or any infrastructure type, and follows the "intentional decoupling" pattern documented in the architecture. No boundary violations.
- **RULES.md:** N/A — file does not exist.
- **ROADMAP.md:** PASS — Milestone 4.2 "Signer & Key Derivation" is present and marked complete. Implementation matches the roadmap description: BIP44 `m/44'/501'/0'` derivation via HdWalletKit + TweetNaCl Ed25519 signing, standalone from `Kit`.

### Critical Issues

None.

### Suggestions

1. **Underlying errors are discarded — harder to debug in production** (`Signer.swift:44-46`, `Signer.swift:64-66`)

   Both `sign(data:)` and `deriveKeyPair(seed:)` catch the underlying library error and replace it with a bare `SignError` enum case that carries no context:

   ```swift
   // sign(data:) — line 44
   } catch {
       throw SignError.signingFailed   // original NaCl error lost
   }

   // deriveKeyPair — line 65
   } catch {
       throw SignError.invalidSeed     // original HdWalletKit/NaCl error lost
   }
   ```

   When a user reports a key derivation failure in production, the error log will show `.invalidSeed` with zero detail about whether `HDWallet` init failed, `privateKey(account:)` threw, or `NaclSign.KeyPair.keyPair(fromSeed:)` rejected the seed bytes.

   **Fix:** Add the underlying error as an associated value while keeping the clean public API:

   ```swift
   enum SignError: Error {
       case invalidSeed(underlying: Error)
       case signingFailed(underlying: Error)
   }
   ```

   Callers still pattern-match on `.invalidSeed` / `.signingFailed`, but debuggers and crash reporters get the root cause via `error.localizedDescription` or `String(describing: error)`.

2. **Dead `catch` branch in `deriveKeyPair`** (`Signer.swift:62-63`)

   ```swift
   } catch let error as SignError {
       throw error
   }
   ```

   No code inside the `do` block can throw a `SignError` — the only throwing calls are `hdWallet.privateKey(account:)` (throws `HDWalletKit` errors) and `NaclSign.KeyPair.keyPair(fromSeed:)` (throws `NaclSignError`). This branch is unreachable dead code. It's harmless but confusing — future readers may wonder what `SignError` it's guarding against.

   **Fix:** Remove the `catch let error as SignError` branch, leaving only the generic `catch`:

   ```swift
   private static func deriveKeyPair(seed: Data) throws -> (publicKey: Data, secretKey: Data) {
       do {
           let hdWallet = HDWallet(seed: seed, coinType: 501, xPrivKey: 0, curve: .ed25519)
           let privateKey = try hdWallet.privateKey(account: 0)
           let privateRaw = privateKey.raw
           return try NaclSign.KeyPair.keyPair(fromSeed: privateRaw)
       } catch {
           throw SignError.invalidSeed
       }
   }
   ```

### Positive Notes

- **Correct derivation path.** `m/44'/501'/0'` with `coinType: 501, xPrivKey: 0, curve: .ed25519` exactly matches both the Android `SolanaBip44` + `DerivableType.BIP44CHANGE` pattern and the established iOS pattern in `TonKitManager.swift` (which uses the identical `HDWallet` + `NaclSign.KeyPair` sequence with `coinType: 607`).
- **Clean use of `privateKey.raw` directly.** The TonKitManager reference uses `Data(privateKey.raw.bytes)`, but since `HDPrivateKey.raw` already returns `Data` (confirmed in HdWalletKit source: `_raw.suffix(32)`), passing it directly to `NaclSign.KeyPair.keyPair(fromSeed:)` is cleaner and avoids an unnecessary copy.
- **EvmKit Signer pattern faithfully followed.** Internal `init`, public static factory methods in an extension (`instance`, `address`, `privateKey`), error enum in a separate `public extension` — all match the EvmKit convention.
- **Architecture alignment.** `Signer` is fully decoupled from `Kit`. No import of Core managers, no reference to `IRpcClient` or storage protocols. It touches only `PublicKey` and `Address` from the Models layer, exactly as the architecture document specifies.
- **Comprehensive documentation.** Every public method and property has doc comments explaining purpose, parameters, return values, and error semantics.
