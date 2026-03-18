## Code Review Summary

**Files Reviewed:** 5 (TokenAccountManager.swift, SplMintLayout.swift, Protocols.swift, SyncManager.swift, Kit.swift)
**Risk Level:** 🟢 Low

### Context Gates

- **ARCHITECTURE.md** — WARN: Architecture states Core must not import concrete infra types and all managers use protocol injection. `TokenAccountManager` correctly depends on `IRpcApiProvider`, `ITransactionStorage`, `IMainStorage`, and `INftClient` — all protocols. Combine event flow follows the prescribed pattern (manager -> delegate -> SyncManager -> Kit -> subject.send on main). No violations.
- **RULES.md** — No `.ai-factory/RULES.md` found. WARN (non-blocking).
- **ROADMAP.md** — Milestone 3.2 is marked `[x]` in the roadmap. No linkage issues.

### Critical Issues

None.

### Suggestions

1. **Missing chunking for `getMultipleAccounts` on new mint addresses** (TokenAccountManager.swift:94)
   The `sync()` method sends all new mint addresses to `rpcApiProvider.getMultipleAccounts(addresses:)` in a single call. Solana's JSON-RPC limits `getMultipleAccounts` to 100 pubkeys per request. If a wallet has 100+ new SPL token mints on first sync (e.g., airdrop-heavy wallets), the RPC call will fail with a "Too many inputs" error, leaving `syncState` stuck at `.notSynced`. `NftClient` already handles this correctly by chunking into 100-element batches (line 53 of NftClient.swift). Apply the same chunking pattern here:
   ```swift
   // Instead of:
   let bufferInfos = try await rpcApiProvider.getMultipleAccounts(addresses: sortedNewMints)

   // Chunk into batches of 100:
   var allBufferInfos: [BufferInfo?] = []
   for chunk in sortedNewMints.chunked(into: 100) {
       let chunkInfos = try await rpcApiProvider.getMultipleAccounts(addresses: Array(chunk))
       allBufferInfos.append(contentsOf: chunkInfos)
   }
   ```

2. **Unused `existingMintAddresses` parameter** (TokenAccountManager.swift:174)
   `addAccount(receivedTokenAccounts:existingMintAddresses:)` has the second parameter marked as `_` (discarded). If the parameter is intentionally reserved for future use by `TransactionSyncer` (milestone 3.4), this is acceptable. However, the current `sync()` method independently re-discovers which mints are new via `storage.mintAccount(address:)`, making the parameter redundant. Consider either removing the parameter or using it to pre-filter known mints and avoid redundant storage lookups during the subsequent `sync()`.

3. **Duplicate `Data.readLE` private extension** (SplMintLayout.swift:94, MetaplexMetadataLayout.swift:195)
   Both files define an identical `private extension Data { func readLE<T: FixedWidthInteger>(offset:) -> T }`. While `private` scoping prevents compilation conflicts, this is code duplication. Consider extracting it to a shared internal `Data+LE.swift` extension file in `Helper/`.

4. **Silent storage error swallowing** (TokenAccountManager.swift:144-145)
   `try? storage.save(tokenAccounts:)` and `try? storage.save(mintAccounts:)` silently discard storage write errors. If the database write fails, `storage.fullTokenAccounts()` on the next line returns stale data, and the delegate receives outdated token account lists with no error indication. This matches `BalanceManager`'s pattern (`try? storage.save(balance:)`) and the Android code, so it's a conscious trade-off — but worth noting that a database corruption or full-disk scenario would silently produce stale data without surfacing an error to the user.

### Positive Notes

- **Excellent pattern consistency with BalanceManager.** The `syncState` `didSet` guard, `weak var delegate`, `DispatchQueue.main.async` notification dispatch, `guard !syncState.syncing` reentrancy protection, and `stop(error:)` methods are all structurally identical. This makes the codebase easy to navigate.

- **Correct delegate wiring chain.** `TokenAccountManager` -> `ITokenAccountManagerDelegate` (SyncManager) -> `ISyncManagerDelegate` (Kit) -> Combine subjects. All `send()` calls dispatch on `DispatchQueue.main` as required by the architecture.

- **Clean NFT detection logic.** The multi-layered NFT detection (SplMintLayout basic check + Metaplex tokenStandard enum + collection verification) correctly covers all Metaplex token standards including `programmableNonFungible` (pNFTs). The fallback using `try?` for Metaplex metadata ensures that a Metaplex fetch failure doesn't block the entire sync.

- **Proper initial state seeding in Kit.instance().** `fungibleTokenAccountsSubject` is seeded from storage before any RPC call, so `Kit.fungibleTokenAccounts()` returns correct data immediately after instantiation.

- **SplMintLayout is well-structured** with clear byte offset documentation, proper bounds checking, and a clean `ParseError` type. The `Data.readLE` helper using `loadUnaligned` is correct and avoids alignment issues.

- **`MintAccount.addMintAccount` uses `.ignore` conflict resolution** while `save(mintAccounts:)` uses `.replace`. This correctly prevents `addTokenAccount()` pre-registration from clobbering enriched Metaplex data, while full sync upserts always update to the latest.

REVIEW_PASS
