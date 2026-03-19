## Code Review Summary

**Files Reviewed:** 8
**Risk Level:** 🔴 High

### Context Gates
- **ARCHITECTURE.md:** WARN — No architectural violations. `NftClient` lives in `Api/`, `MetaplexMetadataLayout` in `Helper/`, protocols in `Core/Protocols.swift` — all consistent with layer rules. Kit.instance() correctly wires new dependencies.
- **RULES.md:** Not present (skipped).
- **ROADMAP.md:** WARN — Milestone 3.3 is marked `[x]` in the roadmap but the Completed table at the bottom has no entry for it.

### Critical Issues

1. **Compile-time error: `chunked(into:)` called without `.hs` namespace** — `NftClient.swift:53`

   ```swift
   // Current (broken):
   for chunk in pdaMappings.chunked(into: chunkSize) {

   // Correct:
   for chunk in pdaMappings.hs.chunked(into: chunkSize) {
   ```

   `Array` has no native `chunked(into:)` method. The `HsExtensions.Swift` dependency provides it via `array.hs.chunked(into:)` (namespaced under a nested `HsExtensions` struct). The direct call will fail at compile time. This makes `NftClient.findAllByMintList()` entirely non-functional, which means **both** `TokenAccountManager.sync()` and `TransactionSyncer.resolveMintAccounts()` will crash at build time — blocking all NFT detection and Metaplex metadata enrichment.

   **Fix:** Change line 53 of `NftClient.swift` to `pdaMappings.hs.chunked(into: chunkSize)` and add `import HsExtensions` at the top of the file.

### Suggestions

2. **Duplicate `readLE` private extension** — `SplMintLayout.swift:92-99` and `MetaplexMetadataLayout.swift:195-199`

   Both files define an identical `private extension Data { func readLE<T: FixedWidthInteger>(offset:) -> T }`. While this compiles (private extensions are file-scoped), it's unnecessary duplication. Extract it into a shared internal extension (e.g., `Helper/Data+ReadLE.swift`) so both parsers and any future binary parsers can reuse it.

3. **DDL conflict policy mismatch for `mintAccounts` table** — `TransactionStorage.swift:88`

   The table is created with `t.primaryKey([...], onConflict: .ignore)` but `MintAccount.persistenceConflictPolicy` uses `.replace`. The model's policy wins at the SQL statement level (GRDB inserts with `INSERT OR REPLACE`), so behavior is correct. However, the DDL-level `.ignore` is misleading — a reader inspecting the migration would believe inserts are idempotent/silent, when in reality `save(mintAccounts:)` replaces existing rows. Change the DDL to `onConflict: .replace` to match the model's intent and avoid confusion.

### Positive Notes

- **PDA derivation** (`PublicKey.swift:62-134`) is well-implemented. The `isOnEd25519Curve` check using `Curve25519.Signing.PublicKey` is the correct approach for CryptoKit, and the comment documents verification against a known PDA (USDC mint).
- **Metaplex binary parsing** (`MetaplexMetadataLayout.swift`) is thorough — handles all optional fields (creators, edition nonce, token standard, collection) with proper bounds checking and graceful nil fallback for truncated data.
- **NFT detection logic** in both `TokenAccountManager` and `TransactionSyncer` correctly mirrors Android's full hierarchy (decimals check, supply+authority heuristic, then Metaplex token standard check including `programmableNonFungible`).
- **`NftClient` design** correctly filters by Metaplex program owner, chunks requests to 100 (matching Android), and silently skips unparseable accounts.
- **`JupiterApiService`** follows the EvmKit pattern cleanly — own `NetworkManager`, proper API key header, descriptive error for empty responses.
- **Kit wiring** in `Kit.instance()` properly injects `nftClient` into both `TokenAccountManager` and `TransactionSyncer`, and stores `jupiterApiService` for future use.
