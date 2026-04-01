# ATA Transaction Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Discover incoming SPL token transfers (swaps, bridge deposits) by syncing transaction signatures for Associated Token Account (ATA) addresses, not only the wallet address.

**Architecture:** Extract signature fetching from `TransactionSyncer` into a pluggable `ISignatureProvider` protocol with a single method. Each provider fully owns its cursors — no shared cursor state. Default implementation composes a wallet-address provider and an ATA-address provider. To switch to Helius DAS API — implement `ISignatureProvider` and inject it. To disable ATA sync — remove the ATA provider from the composite.

**Tech Stack:** Swift, SolanaKit (GRDB, Combine, async/await)

---

## Problem

`getSignaturesForAddress(walletAddress)` does not return transactions where the wallet is only the **owner** of a token account (ATA) but not a direct participant in the transaction's account keys. Cross-chain swaps and bridge deposits send tokens to the user's ATA directly, signed by the bridge operator — the wallet address never appears in account keys.

## Solution

For each SPL token account the user holds, also call `getSignaturesForAddress(ataAddress)` to discover transactions targeting that ATA. Merge all signatures, deduplicate, and feed through the existing parse pipeline.

## File Structure

```
Sources/SolanaKit/
├── Transactions/
│   ├── SignatureProviders/
│   │   ├── ISignatureProvider.swift             ← NEW: protocol (1 method)
│   │   ├── WalletSignatureProvider.swift        ← NEW: wallet address provider
│   │   ├── TokenAccountSignatureProvider.swift  ← NEW: ATA addresses provider
│   │   └── CompositeSignatureProvider.swift     ← NEW: merges multiple providers
│   ├── TransactionSyncer.swift                  ← MODIFY: delegate to signatureProvider
│   └── PendingTransactionSyncer.swift           ← no change
├── Core/
│   ├── Kit.swift                                ← MODIFY: wire providers + cursor migration
│   └── Protocols.swift                          ← no change
├── Database/
│   └── TransactionStorage.swift                 ← MODIFY: add fungibleTokenAccounts()
```

## Design Decisions

1. **Single-method protocol** — `ISignatureProvider` has one method: `fetchNewSignatures()`. Each provider fully owns its cursors — reads them at fetch start, writes them at fetch end. No shared cursor state, no coupling between fetch and save.

2. **One cursor per source** — `WalletSignatureProvider` uses cursor `"rpc/wallet"`. `TokenAccountSignatureProvider` uses cursor `"rpc/ata/<ata_address>"` per ATA. Independent incremental sync for each.

3. **Cursor migration** — GRDB migration renames `"rpc/getSignaturesForAddress"` → `"rpc/wallet"` to avoid full re-sync on existing wallets.

4. **ATA filtering** — Only sync ATAs with `balance > 0` and `isNft == false`. Skips dead accounts and NFTs.

5. **Partial error tolerance** — If one ATA fails, log and continue with remaining ATAs. Don't fail the entire sync.

6. **Deduplication by signature** — The same transaction can appear in both wallet and ATA results. `CompositeSignatureProvider` deduplicates by signature string.

7. **Page size for ATAs** — 100 signatures per ATA (vs 1000 for wallet). Most ATAs have few transactions. Max 3 pages on first sync (300 signatures cap per ATA).

---

### Task 1: ISignatureProvider Protocol

**Files:**
- Create: `Sources/SolanaKit/Transactions/SignatureProviders/ISignatureProvider.swift`

- [ ] **Step 1: Create the protocol file**

```swift
import Foundation

/// Abstraction for fetching new transaction signatures.
///
/// Implementations can use Solana RPC `getSignaturesForAddress`, Helius DAS API,
/// or any other indexer. Each provider fully owns its sync cursors —
/// reads them at fetch start, writes them at fetch end.
protocol ISignatureProvider {
    /// Fetches all new signatures since the provider's last saved cursor.
    /// On success, the provider saves its cursor(s) internally before returning.
    func fetchNewSignatures() async throws -> [SignatureInfo]
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/SolanaKit/Transactions/SignatureProviders/ISignatureProvider.swift
git commit -m "feat: add ISignatureProvider protocol for pluggable signature fetching"
```

---

### Task 2: WalletSignatureProvider

**Files:**
- Create: `Sources/SolanaKit/Transactions/SignatureProviders/WalletSignatureProvider.swift`

- [ ] **Step 1: Implement WalletSignatureProvider**

Extracts the existing `fetchAllSignatures()` logic from `TransactionSyncer`. Manages its own cursor `"rpc/wallet"`.

```swift
import Foundation
import HsToolKit

/// Fetches transaction signatures for the main wallet address via `getSignaturesForAddress`.
///
/// Manages its own incremental sync cursor under `"rpc/wallet"`.
final class WalletSignatureProvider: ISignatureProvider {
    private static let syncSourceName = "rpc/wallet"
    private let pageSize = 1000

    private let address: String
    private let rpcApiProvider: IRpcApiProvider
    private let storage: ITransactionStorage
    private let logger: Logger?

    init(address: String, rpcApiProvider: IRpcApiProvider, storage: ITransactionStorage, logger: Logger? = nil) {
        self.address = address
        self.rpcApiProvider = rpcApiProvider
        self.storage = storage
        self.logger = logger
    }

    func fetchNewSignatures() async throws -> [SignatureInfo] {
        let until = storage.lastSyncedTransaction(syncSourceName: Self.syncSourceName)?.hash
        logger?.debug("WalletSignatureProvider: fetching for \(address), until: \(until ?? "nil")")

        var allSignatures: [SignatureInfo] = []
        var before: String?

        repeat {
            let chunk = try await rpcApiProvider.getSignaturesForAddress(
                address: address,
                limit: pageSize,
                before: before,
                until: until
            )
            allSignatures.append(contentsOf: chunk)
            before = chunk.last?.signature
            if chunk.count < pageSize { break }
        } while true

        // Save cursor on success.
        if let newestSignature = allSignatures.first {
            try? storage.save(lastSyncedTransaction: LastSyncedTransaction(
                syncSourceName: Self.syncSourceName,
                hash: newestSignature
            ))
        }

        logger?.debug("WalletSignatureProvider: fetched \(allSignatures.count) signature(s)")
        return allSignatures
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/SolanaKit/Transactions/SignatureProviders/WalletSignatureProvider.swift
git commit -m "feat: extract wallet signature fetching into WalletSignatureProvider"
```

---

### Task 3: Add fungibleTokenAccounts query to TransactionStorage

**Files:**
- Modify: `Sources/SolanaKit/Database/TransactionStorage.swift`
- Modify: `Sources/SolanaKit/Core/Protocols.swift`

- [ ] **Step 1: Add `fungibleTokenAccounts()` to ITransactionStorage protocol**

In `Protocols.swift`, add to `ITransactionStorage`:

```swift
func fungibleTokenAccounts() -> [TokenAccount]
```

- [ ] **Step 2: Implement in TransactionStorage**

In `TransactionStorage.swift`, add:

```swift
func fungibleTokenAccounts() -> [TokenAccount] {
    try! dbPool.read { db in
        let sql = """
            SELECT ta.* FROM \(TokenAccount.databaseTableName) AS ta
            INNER JOIN \(MintAccount.databaseTableName) AS ma
                ON ta.\(TokenAccount.Columns.mintAddress.name) = ma.\(MintAccount.Columns.address.name)
            WHERE CAST(ta.\(TokenAccount.Columns.balance.name) AS REAL) > 0
                AND ma.\(MintAccount.Columns.isNft.name) = 0
        """
        return try TokenAccount.fetchAll(db, sql: sql)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/SolanaKit/Database/TransactionStorage.swift Sources/SolanaKit/Core/Protocols.swift
git commit -m "feat: add fungibleTokenAccounts() query filtered by balance > 0 and non-NFT"
```

---

### Task 4: TokenAccountSignatureProvider

**Files:**
- Create: `Sources/SolanaKit/Transactions/SignatureProviders/TokenAccountSignatureProvider.swift`

- [ ] **Step 1: Implement TokenAccountSignatureProvider**

Fetches signatures for each fungible ATA with balance > 0. Each ATA has its own cursor. Tolerates individual ATA failures.

```swift
import Foundation
import HsToolKit

/// Fetches transaction signatures for all known fungible Associated Token Accounts (ATAs)
/// via `getSignaturesForAddress`.
///
/// Discovers incoming SPL transfers where the wallet address is only the token
/// account owner, not a direct transaction participant.
///
/// Each ATA has an independent sync cursor stored under `"rpc/ata/<ata_address>"`.
/// Individual ATA failures are logged and skipped — remaining ATAs continue syncing.
final class TokenAccountSignatureProvider: ISignatureProvider {
    private let pageSize = 100
    private let maxFirstSyncPages = 3

    private let rpcApiProvider: IRpcApiProvider
    private let storage: ITransactionStorage
    private let logger: Logger?

    init(rpcApiProvider: IRpcApiProvider, storage: ITransactionStorage, logger: Logger? = nil) {
        self.rpcApiProvider = rpcApiProvider
        self.storage = storage
        self.logger = logger
    }

    func fetchNewSignatures() async throws -> [SignatureInfo] {
        let tokenAccounts = storage.fungibleTokenAccounts()
        guard !tokenAccounts.isEmpty else {
            logger?.debug("TokenAccountSignatureProvider: no fungible token accounts, skipping")
            return []
        }

        logger?.debug("TokenAccountSignatureProvider: syncing \(tokenAccounts.count) ATA(s)")

        var allSignatures: [SignatureInfo] = []

        for account in tokenAccounts {
            let ataAddress = account.address
            let cursorName = Self.cursorName(ataAddress: ataAddress)
            let until = storage.lastSyncedTransaction(syncSourceName: cursorName)?.hash
            let isFirstSync = until == nil

            do {
                var ataSignatures: [SignatureInfo] = []
                var before: String?
                var pageCount = 0

                repeat {
                    let chunk = try await rpcApiProvider.getSignaturesForAddress(
                        address: ataAddress,
                        limit: pageSize,
                        before: before,
                        until: until
                    )
                    ataSignatures.append(contentsOf: chunk)
                    before = chunk.last?.signature
                    pageCount += 1

                    if chunk.count < pageSize { break }
                    if isFirstSync, pageCount >= maxFirstSyncPages { break }
                } while true

                if let newestSignature = ataSignatures.first {
                    try? storage.save(lastSyncedTransaction: LastSyncedTransaction(
                        syncSourceName: cursorName,
                        hash: newestSignature
                    ))
                    logger?.debug("TokenAccountSignatureProvider: ATA \(ataAddress) — \(ataSignatures.count) new signature(s)")
                }

                allSignatures.append(contentsOf: ataSignatures)
            } catch {
                logger?.error("TokenAccountSignatureProvider: ATA \(ataAddress) failed: \(error), skipping")
                continue
            }
        }

        logger?.debug("TokenAccountSignatureProvider: total \(allSignatures.count) signature(s)")
        return allSignatures
    }

    static func cursorName(ataAddress: String) -> String {
        "rpc/ata/\(ataAddress)"
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/SolanaKit/Transactions/SignatureProviders/TokenAccountSignatureProvider.swift
git commit -m "feat: add TokenAccountSignatureProvider for ATA-based signature discovery"
```

---

### Task 5: CompositeSignatureProvider

**Files:**
- Create: `Sources/SolanaKit/Transactions/SignatureProviders/CompositeSignatureProvider.swift`

- [ ] **Step 1: Implement CompositeSignatureProvider**

Merges results from multiple providers, deduplicates by signature. Each child provider already saved its own cursors during `fetchNewSignatures()`.

```swift
import Foundation
import HsToolKit

/// Composes multiple `ISignatureProvider` instances and merges their results.
///
/// Deduplicates signatures (the same transaction can appear from both wallet
/// and ATA providers). Each child provider manages its own cursors internally.
final class CompositeSignatureProvider: ISignatureProvider {
    private let providers: [ISignatureProvider]
    private let logger: Logger?

    init(providers: [ISignatureProvider], logger: Logger? = nil) {
        self.providers = providers
        self.logger = logger
    }

    func fetchNewSignatures() async throws -> [SignatureInfo] {
        var allSignatures: [SignatureInfo] = []

        for provider in providers {
            let signatures = try await provider.fetchNewSignatures()
            allSignatures.append(contentsOf: signatures)
        }

        // Deduplicate by signature hash, preserving insertion order.
        var seen = Set<String>()
        let unique = allSignatures.filter { seen.insert($0.signature).inserted }

        let duplicateCount = allSignatures.count - unique.count
        if duplicateCount > 0 {
            logger?.debug("CompositeSignatureProvider: removed \(duplicateCount) duplicate(s)")
        }

        logger?.debug("CompositeSignatureProvider: \(unique.count) unique signature(s) from \(providers.count) provider(s)")
        return unique
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/SolanaKit/Transactions/SignatureProviders/CompositeSignatureProvider.swift
git commit -m "feat: add CompositeSignatureProvider for merging multiple signature sources"
```

---

### Task 6: Refactor TransactionSyncer to Use ISignatureProvider

**Files:**
- Modify: `Sources/SolanaKit/Transactions/TransactionSyncer.swift`

- [ ] **Step 1: Replace inline signature fetching with provider**

Changes to `TransactionSyncer`:

1. **Remove** these constants:
```swift
private let signaturesPageSize = 1000
private let syncSourceName = "rpc/getSignaturesForAddress"
```

2. **Add** to dependencies section:
```swift
private let signatureProvider: ISignatureProvider
```

3. **Update init** — add `signatureProvider` parameter, fix logger bug (use passed logger, not hardcoded):
```swift
init(
    address: String,
    rpcApiProvider: IRpcApiProvider,
    nftClient: INftClient,
    storage: ITransactionStorage,
    transactionManager: TransactionManager,
    tokenAccountManager: TokenAccountManager,
    pendingTransactionSyncer: PendingTransactionSyncer,
    signatureProvider: ISignatureProvider,
    logger: Logger? = nil
) {
    self.address = address
    self.rpcApiProvider = rpcApiProvider
    self.nftClient = nftClient
    self.storage = storage
    self.transactionManager = transactionManager
    self.tokenAccountManager = tokenAccountManager
    self.pendingTransactionSyncer = pendingTransactionSyncer
    self.signatureProvider = signatureProvider
    self.logger = logger
}
```

4. **In `sync()`**, replace:
```swift
let signatureInfos = try await fetchAllSignatures()
```
with:
```swift
let signatureInfos = try await signatureProvider.fetchNewSignatures()
```

5. **Remove cursor saving** (step 12 in sync). Each provider already saves its own cursor. Delete:
```swift
// Step 12: Save the incremental sync cursor (newest signature).
if let newestSignature = signatures.first {
    ...
}
```

6. **Delete** the entire `fetchAllSignatures()` private method.

- [ ] **Step 2: Verify build compiles (in Xcode)**

- [ ] **Step 3: Commit**

```bash
git add Sources/SolanaKit/Transactions/TransactionSyncer.swift
git commit -m "refactor: delegate signature fetching to ISignatureProvider in TransactionSyncer"
```

---

### Task 7: Wire Providers in Kit.instance() + Cursor Migration

**Files:**
- Modify: `Sources/SolanaKit/Core/Kit.swift`
- Modify: `Sources/SolanaKit/Database/TransactionStorage.swift` (migration)

- [ ] **Step 1: Add GRDB migration for cursor rename**

In `TransactionStorage.init()`, add a migration after existing migrations:

```swift
migrator.registerMigration("Rename wallet sync cursor") { db in
    try db.execute(
        sql: "UPDATE LastSyncedTransaction SET syncSourceName = ? WHERE syncSourceName = ?",
        arguments: ["rpc/wallet", "rpc/getSignaturesForAddress"]
    )
}
```

- [ ] **Step 2: Wire providers in Kit.instance()**

In the factory method, after `PendingTransactionSyncer` and before `TransactionSyncer`, add:

```swift
let walletSignatureProvider = WalletSignatureProvider(
    address: address,
    rpcApiProvider: rpcApiProvider,
    storage: transactionStorage,
    logger: logger
)
let tokenAccountSignatureProvider = TokenAccountSignatureProvider(
    rpcApiProvider: rpcApiProvider,
    storage: transactionStorage,
    logger: logger
)
let signatureProvider = CompositeSignatureProvider(
    providers: [walletSignatureProvider, tokenAccountSignatureProvider],
    logger: logger
)
```

Update `TransactionSyncer` init:

```swift
let transactionSyncer = TransactionSyncer(
    address: address,
    rpcApiProvider: rpcApiProvider,
    nftClient: nftClient,
    storage: transactionStorage,
    transactionManager: transactionManager,
    tokenAccountManager: tokenAccountManager,
    pendingTransactionSyncer: pendingTransactionSyncer,
    signatureProvider: signatureProvider,
    logger: logger
)
```

To **disable** ATA sync (one-line change):
```swift
let signatureProvider = CompositeSignatureProvider(
    providers: [walletSignatureProvider],
    logger: logger
)
```

To **switch to Helius** (one-line change):
```swift
let signatureProvider = HeliusSignatureProvider(
    address: address, apiKey: heliusApiKey,
    storage: transactionStorage, logger: logger
)
```

- [ ] **Step 3: Verify build compiles (in Xcode)**

- [ ] **Step 4: Commit**

```bash
git add Sources/SolanaKit/Core/Kit.swift Sources/SolanaKit/Database/TransactionStorage.swift
git commit -m "feat: wire CompositeSignatureProvider in Kit + migrate cursor name"
```

---

## Verification

After all tasks complete:

1. **Build**: Open in Xcode, verify it compiles without errors.
2. **Test with existing wallet**: Verify cursor migration works — no full re-sync.
3. **Test swap**: Execute a Solana swap via USwap. After the incoming SPL transfer arrives on-chain, verify:
   - `TokenAccountSignatureProvider` finds the incoming tx signature via the ATA address
   - `TransactionSyncer` parses it with proper token transfer data
   - The transaction appears in the wallet's transaction list
4. **Test disable**: Remove `tokenAccountSignatureProvider` from composite array — verify only wallet-address sync runs.
5. **Test partial failure**: Temporarily break one ATA's cursor — verify other ATAs still sync.
