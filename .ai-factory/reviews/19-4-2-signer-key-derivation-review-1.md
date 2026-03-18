# Review: 4.2 Signer & Key Derivation

**File reviewed:** `Sources/SolanaKit/Core/Signer.swift` (121 lines, new file)
**Plan:** `.ai-factory/plans/19-4-2-signer-key-derivation.md`

---

## Verification Summary

| Check | Status |
|-------|--------|
| Derivation path matches Android (`m/44'/501'/0'`) | OK |
| HdWalletKit API usage (`HDWallet`, `privateKey(account:)`, `.raw`) | OK |
| TweetNaCl API usage (`keyPair(fromSeed:)`, `signDetached`) | OK |
| Parameter types all `Data` (matches TweetNaCl signatures) | OK |
| `PublicKey(data:)` and `Address(publicKey:)` types exist | OK |
| Matches TonKitManager.swift Ed25519 derivation pattern | OK |
| Error handling wraps underlying errors | OK |
| No compilation errors (platform constraints are pre-existing) | OK |
| Plan tasks all addressed | OK |

---

## Detailed Findings

### Correctness

1. **Derivation path is correct.** `HDWallet(seed:, coinType: 501, xPrivKey: 0, curve: .ed25519)` + `privateKey(account: 0)` produces `m/44'/501'/0'` — matches Android's `DerivableType.BIP44CHANGE` and `TonKitManager.swift:182` (which uses the same pattern with coinType 607 for TON).

2. **`privateKey.raw` returns `Data` (32 bytes).** `HDPrivateKey.raw` is `_raw.suffix(32)` which strips the leading 0x00 prefix byte. This is already a proper `Data` value. TonKitManager uses `Data(privateKey.raw.bytes)` for a defensive copy, but using `.raw` directly is equivalent and simpler — `keyPair(fromSeed:)` accepts `Data`.

3. **TweetNaCl API calls are correct.** `NaclSign.KeyPair.keyPair(fromSeed:)` takes 32-byte `Data`, returns `(publicKey: Data, secretKey: Data)`. `NaclSign.signDetached(message:secretKey:)` takes `Data`, returns 64-byte `Data`. Both match the call sites exactly.

4. **`force_try` on `PublicKey(data:)` is safe.** `PublicKey(data:)` throws only when `data.count != 32`. The public key from `NaclSign.KeyPair` is always exactly 32 bytes. This invariant is well-documented in the comments. Used in two places (lines 30, 94) — both safe.

### Minor Observations (non-blocking)

5. **Dead catch clause (line 62).** `catch let error as SignError { throw error }` — no code inside the `do` block can throw a `SignError` (`HDWallet.init` doesn't throw, `privateKey()` throws HdWalletKit errors, `keyPair()` throws `NaclSignError`). This clause is harmless but unreachable. It may serve as defensive future-proofing if the method is ever refactored to call other `SignError`-throwing code.

6. **`address` is a computed `var` rather than stored `let`.** The plan says "Expose `public let address`" but the implementation uses a computed property. Functionally identical — the computation is trivial (wrapping 32 bytes). A stored `let` would avoid recomputation on repeated access but adds init complexity. Not a bug.

7. **Error cases don't carry the underlying error.** `SignError.invalidSeed` and `.signingFailed` discard the original error. This makes debugging harder if something unexpected fails. Consider `case invalidSeed(Error)` for diagnostics. Not blocking — matches the plan's specification and the EvmKit pattern.

8. **No secure memory zeroing for `secretKey`.** The 64-byte NaCl secret key lives in a `Data` value with no zeroing on deallocation. This is a known Swift limitation — `Data` is a value type with CoW and there's no standard secure deallocation. EvmKit has the same characteristic. Not actionable without a custom secure buffer type.

### Android Parity

9. **API surface matches Android.** Android's `Signer` has `getInstance(seed)`, `address(seed)`, `privateKey(seed)` — iOS has `instance(seed:)`, `address(seed:)`, `privateKey(seed:)`. Android's `Signer` doesn't expose `sign()` directly (signing goes through `Account`), but iOS adding `sign(data:)` is cleaner for the Kit architecture.

---

## Verdict

Clean, correct implementation. Derivation path verified against Android reference and TonKitManager. All API calls match their library signatures. No runtime bugs, no type mismatches, no security vulnerabilities beyond inherent Swift limitations.

REVIEW_PASS
