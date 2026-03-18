# Review: 3.3 Jupiter Token Metadata + Metaplex NFT Detection

**Reviewer:** Claude Opus 4.6
**Date:** 2026-03-18
**Build status:** Compiles (iOS target, xcodebuild)
**Files reviewed:** All 10 changed/new files read in full + Android reference code

---

## Critical Issues

### C1: `MetaplexTokenStandard` raw values are wrong — NFT detection will misclassify tokens

**File:** `Sources/SolanaKit/Helper/MetaplexMetadataLayout.swift:43-49`

The enum raw values do not match the Metaplex Token Metadata Program's Borsh serialization order. The on-chain Rust enum (`mpl-token-metadata/programs/token-metadata/program/src/state/metadata.rs`) defines:

```rust
pub enum TokenStandard {
    NonFungible,                    // 0
    FungibleAsset,                  // 1
    Fungible,                       // 2
    NonFungibleEdition,             // 3
    ProgrammableNonFungible,        // 4
    ProgrammableNonFungibleEdition, // 5
}
```

The iOS code has:

```swift
enum MetaplexTokenStandard: UInt8 {
    case fungible               = 0  // WRONG: should be nonFungible
    case nonFungible            = 1  // WRONG: should be fungibleAsset
    case fungibleAsset          = 2  // WRONG: should be fungible
    case nonFungibleEdition     = 3  // correct
    case programmableNonFungible = 4  // correct
}
```

**Impact:** The first three values are swapped. Runtime consequences for `TokenAccountManager.sync()` NFT detection:

| On-chain byte | Actual meaning | iOS maps to | NFT check result | Correct result |
|---|---|---|---|---|
| 0 | NonFungible | `.fungible` | NOT NFT | IS NFT |
| 1 | FungibleAsset | `.nonFungible` | IS NFT | IS NFT (lucky) |
| 2 | Fungible | `.fungibleAsset` | IS NFT | NOT NFT |

- **False negatives:** Real NFTs with `NonFungible` token standard (byte 0) that don't satisfy the basic `supply==1 && mintAuthority==nil` heuristic will be missed and shown as fungible tokens.
- **False positives:** Real fungible tokens with `Fungible` token standard (byte 2) and `decimals==0` will be classified as NFTs and hidden from the fungible token list.

**Fix:** Correct the raw values:

```swift
enum MetaplexTokenStandard: UInt8 {
    case nonFungible            = 0
    case fungibleAsset          = 1
    case fungible               = 2
    case nonFungibleEdition     = 3
    case programmableNonFungible = 4
}
```

Also add `.programmableNonFungible` to the NFT detection check in `TokenAccountManager.swift` if parity with newer Metaplex behavior is desired (Android omits it, but pNFTs are NFTs by definition).

---

## High-Severity Issues

### H1: `isOnEd25519Curve` may not actually validate curve membership — PDA derivation could silently fail

**File:** `Sources/SolanaKit/Models/PublicKey.swift:119-123`

```swift
private static func isOnEd25519Curve(_ bytes: Data) -> Bool {
    guard bytes.count == 32 else { return false }
    return (try? Curve25519.Signing.PublicKey(rawRepresentation: bytes)) != nil
}
```

Apple's `Curve25519.Signing.PublicKey(rawRepresentation:)` is documented to throw only `CryptoKitError.incorrectParameterSize` (wrong byte count). It is **not documented** to validate that the 32 bytes represent a valid compressed Edwards point on the Ed25519 curve. If the underlying implementation (BoringSSL/CoreCrypto) simply stores the raw bytes without decompression, then `isOnEd25519Curve` returns `true` for ALL 32-byte inputs.

**Impact if broken:** `findProgramAddress` would throw `.couldNotFindValidAddress` for every mint. `NftClient.findAllByMintList` uses `try?` on PDA derivation (line 40-41 of NftClient.swift), so failures are silently swallowed — the method returns an empty dictionary, and NFT detection falls back to the basic `supply==1 && mintAuthority==nil` heuristic only. No crash, but Metaplex metadata (name, symbol, uri, collection) would never be populated.

**Recommendation:** Verify with a known test vector. For example, the Metaplex metadata PDA for the USDC mint (`EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v`) should derive to `2uMBJkes3jHP73XNFQ5iKiX3MoDaKo5RsYfLjETyDox`. If `metadataPDA` throws for this input, the CryptoKit check is broken and must be replaced with a proper Ed25519 point decompression (e.g., using TweetNaCl which is already a dependency, or a manual modular square root check).

---

## Minor Issues

### M1: `MintAccount` docstring still references SolanaFM

**File:** `Sources/SolanaKit/Models/MintAccount.swift:7-8`

```swift
/// Stores mint metadata (decimals, supply) and optional enrichment from SolanaFM
/// (name, symbol, URI, collection address). First-write-wins conflict policy mirrors
```

The enrichment source is now Metaplex on-chain metadata (and Jupiter for future use). The docstring still says "SolanaFM" and "First-write-wins" despite the conflict policy being changed to `.replace`. The per-field docstrings on lines 19-25 also reference "SolanaFM metadata enrichment".

### M2: Comment says "in parallel" but calls are sequential

**File:** `Sources/SolanaKit/Core/TokenAccountManager.swift:96`

```swift
// 4a. Fetch Metaplex on-chain metadata in parallel for the same mints.
let metaplexMap = (try? await nftClient.findAllByMintList(mintAddresses: sortedNewMints)) ?? [:]
```

The call is `await`ed sequentially after `getMultipleAccounts` on line 94. Both are independent and could be parallelized with `async let` to halve latency, but currently they run sequentially. The comment is misleading.

### M3: Duplicate `Array.chunked(into:)` private extension

**Files:** `Sources/SolanaKit/Api/NftClient.swift:74-81` and `Sources/SolanaKit/Api/RpcApiProvider.swift:134-140`

Identical `private extension Array` with `func chunked(into:)` exists in both files. While both are `private` (no compile conflict), this is unnecessary duplication. Consider extracting to a shared internal extension.

### M4: `JupiterApiService` response format assumption

**File:** `Sources/SolanaKit/Api/JupiterApiService.swift:54`

```swift
guard let array = json as? [[String: Any]] else {
```

The Jupiter `/tokens/v2/search` endpoint may change its response shape. If the API wraps results in an object (e.g., `{"tokens": [...]}`), the cast to `[[String: Any]]` would fail with `.invalidResponse`. Not a current bug, but fragile. The Android reference code should be checked for how it handles the response.

---

## Design Observations (non-blocking)

1. **Kit stores `jupiterApiService` as concrete `JupiterApiService`** (Kit.swift:23) — should be `IJupiterApiService` for protocol-first consistency and testability. Same for NftClient not being stored on Kit (it's passed to TokenAccountManager via protocol, which is correct).

2. **`NftClient` propagates RPC errors** — if the `getMultipleAccounts` call throws for one chunk, the entire `findAllByMintList` call throws. The `try?` in `TokenAccountManager.sync()` line 97 catches this gracefully, so it's fine, but partial results from earlier chunks are lost.

3. **No `programmableNonFungible` in NFT check** — matches Android parity, but pNFTs (Metaplex v1.3+) are NFTs by definition. Android likely omits this because it was added after their implementation. Consider adding for correctness if the enum values are fixed.

---

## Summary

| Severity | Count | Blocking? |
|---|---|---|
| Critical | 1 (C1: wrong enum values) | Yes |
| High | 1 (H1: PDA curve check) | Needs verification |
| Minor | 4 | No |

The implementation is well-structured, follows established patterns correctly, and the integration wiring is clean. The critical enum value bug (C1) must be fixed before merge — it will cause real NFTs to be shown as fungible tokens and vice versa. The CryptoKit PDA check (H1) should be verified with a test vector to confirm it works.

REVIEW_FAIL: Fix C1 (MetaplexTokenStandard raw values) and verify H1 (isOnEd25519Curve) before proceeding.
