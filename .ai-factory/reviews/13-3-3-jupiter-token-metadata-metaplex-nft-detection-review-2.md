# Review 2: 3.3 Jupiter Token Metadata + Metaplex NFT Detection

**Reviewer:** Claude Opus 4.6
**Date:** 2026-03-18
**Build status:** Compiles (iOS target, xcodebuild — BUILD SUCCEEDED)
**Files reviewed:** All 10 changed/new files read in full
**Context:** Second review after fixes from review-1

---

## Review-1 Issue Resolution

| Issue | Status | Notes |
|---|---|---|
| C1: MetaplexTokenStandard raw values wrong | **Fixed** | Enum now matches Rust spec: nonFungible=0, fungibleAsset=1, fungible=2, nonFungibleEdition=3, programmableNonFungible=4 |
| H1: isOnEd25519Curve may not validate | **Addressed** | Docstring updated with BoringSSL explanation + verified against USDC mint PDA. Implementation is sound — `Curve25519.Signing.PublicKey(rawRepresentation:)` does call `ED25519_check_public_key` which performs point decompression |
| M1: MintAccount docstring references SolanaFM | **Fixed** | Now says "Metaplex on-chain metadata" |
| M3: Duplicate chunked extension | **Not an issue** | Only one `chunked(into:)` exists in RpcApiProvider.swift, changed from `private` to `internal` so NftClient can use it |

---

## Critical Issues

None.

---

## High-Severity Issues

None.

---

## Minor Issues

### M1: Database migration says `.ignore` but record policy is `.replace`

**File:** `Sources/SolanaKit/Database/TransactionStorage.swift:88`

```swift
t.primaryKey([MintAccount.Columns.address.name], onConflict: .ignore)
```

The table-level conflict resolution in the migration is `.ignore`, but `MintAccount.persistenceConflictPolicy` is now `.replace`. This works correctly at runtime — GRDB's `record.save(db)` generates `INSERT OR REPLACE`, which overrides the table-level default per SQLite spec. The `addMintAccount` method correctly uses explicit `insert(db, onConflict: .ignore)` to preserve first-write-wins for the pre-registration path. No runtime bug, but the migration and record policy tell different stories — a comment in the migration would help future readers.

### M2: Metaplex failure on first sync leaves records permanently unenriched

**File:** `Sources/SolanaKit/Core/TokenAccountManager.swift:97`

```swift
let metaplexMap = (try? await nftClient.findAllByMintList(mintAddresses: sortedNewMints)) ?? [:]
```

If the Metaplex RPC call fails, mint accounts are saved without name/symbol/uri/collectionAddress. On subsequent syncs, these mints are filtered out (`storage.mintAccount(address:) == nil` returns false), so they're never re-fetched. This is the pre-existing "process new mints only" design (not introduced by this change), but the `.replace` conflict policy now makes a retry path possible without schema changes — a future enrichment pass could re-save the records. Not a bug; documenting for awareness.

### M3: Duplicate private `Data.readLE` extension

**Files:** `Sources/SolanaKit/Helper/MetaplexMetadataLayout.swift:194-200` and `Sources/SolanaKit/Helper/SplMintLayout.swift:94-99`

Identical `private extension Data { func readLE<T> }` in both files. Both work correctly due to private scoping. If either needs a fix, the other won't get it. Consider extracting to a shared internal extension in a `Data+Extensions.swift` file.

### M4: Sequential RPC calls could be parallelized

**File:** `Sources/SolanaKit/Core/TokenAccountManager.swift:94-97`

The `getMultipleAccounts` (line 94) and `nftClient.findAllByMintList` (line 97) calls are independent and could run concurrently with `async let` to reduce sync latency. Currently sequential. Low priority — correctness is fine either way.

---

## Correctness Verification

### MetaplexMetadataLayout binary parsing — traced field by field

| Offset | Field | Size | Code |
|---|---|---|---|
| 0 | key | 1 | `data[cursor]; cursor += 1` ✓ |
| 1 | update_authority | 32 | `Base58.encode(data[cursor..<cursor+32])` ✓ |
| 33 | mint | 32 | Same ✓ |
| 65 | name | 4 + len | `readBorshString` (u32 LE + UTF-8, null-trimmed) ✓ |
| var | symbol | 4 + len | Same ✓ |
| var | uri | 4 + len | Same ✓ |
| var | seller_fee_basis_points | 2 | Skip ✓ |
| var | creators | 1 + opt(4 + N*34) | Creator = address(32) + verified(1) + share(1) ✓ |
| var | primary_sale_happened | 1 | Skip ✓ |
| var | is_mutable | 1 | Skip ✓ |
| var | edition_nonce | 1 + opt(1) | Option\<u8\> ✓ |
| var | token_standard | 1 + opt(1) | Option\<TokenStandard\> with graceful truncation ✓ |
| var | collection | 1 + opt(33) | Option\<verified(1) + key(32)\> with graceful truncation ✓ |

All fields parse correctly. Truncated data (older metadata accounts missing trailing fields) is handled gracefully — `tokenStandard` and `collection` return `nil` instead of throwing.

### NFT detection logic — matches Android + pNFT improvement

| Condition | iOS | Android | Match |
|---|---|---|---|
| decimals != 0 → false | ✓ | ✓ | ✓ |
| supply == 1 && mintAuthority == nil → true | ✓ | ✓ | ✓ |
| tokenStandard == .nonFungible → true | ✓ | ✓ | ✓ |
| tokenStandard == .fungibleAsset → true | ✓ | ✓ | ✓ |
| tokenStandard == .nonFungibleEdition → true | ✓ | ✓ | ✓ |
| tokenStandard == .programmableNonFungible → true | ✓ | ✗ | iOS improvement (correct per Metaplex v1.3+) |

### PDA derivation — correct per Solana spec

Seeds: `["metadata", metaplexTokenMetadataProgram.bytes, mint.bytes]` + bump byte. SHA-256 hash with `"ProgramDerivedAddress"` suffix. Bump iterates 255→0. Curve check rejects points on Ed25519. All consistent with Solana's `findProgramAddress`.

### Kit wiring — clean

- `NftClient` gets same `rpcApiProvider` as other RPC consumers ✓
- `JupiterApiService` gets its own `NetworkManager` (EvmKit pattern) ✓
- `nftClient` injected into `TokenAccountManager` via `INftClient` protocol ✓
- `jupiterApiService` stored on `Kit` for future `TransactionSyncer` use ✓

---

## Summary

| Severity | Count | Blocking? |
|---|---|---|
| Critical | 0 | — |
| High | 0 | — |
| Minor | 4 | No |

All critical and high-severity issues from review-1 have been resolved. The implementation is correct, well-structured, and follows established patterns. The MetaplexTokenStandard enum values now match the Rust spec. The PDA derivation is verified. The NFT detection logic matches Android with a correct pNFT improvement.

REVIEW_PASS
