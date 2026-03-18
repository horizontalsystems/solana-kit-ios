# Solana Kit iOS — Roadmap

> Swift Package porting `solana-kit-android` (Kotlin) to iOS.

## Context

This project is part of a multi-repo workspace. The planner works inside `solana-kit-ios/`, but reference code lives in sibling directories:

```
../solana-kit-android/     ← behavioral reference (WHAT to port)
../EvmKit.Swift/           ← structural reference (HOW to port: Swift Package, GRDB, Combine)
../unstoppable-wallet-ios/ ← integration target (wallet integration is tracked separately in workspace ROADMAP)
```

## Milestones

### Phase 1: Foundation

- [x] **1.1 SPM Package Scaffold** — Create `solana-kit-ios/` with `Package.swift`, directory structure (`Sources/SolanaKit/{Core,Models,Database,Network,NodeRpc,Transactions}/`), and SPM dependencies: GRDB, HdWalletKit.Swift, TweetNaCl (Ed25519 signing, already used in unstoppable-wallet-ios for TON), HsToolKit.Swift
- [x] **1.2 Base58 & Solana Primitives** — Base58 encoder/decoder, compact-u16 encoding (Solana's variable-length integer format), `PublicKey` type (32-byte wrapper with Base58 string representation). These are used everywhere: models, RPC, transaction serialization
- [x] **1.3 Core Models** — `Address` (wraps PublicKey), `SyncState` (enum with associated values), `RpcSource` (endpoint + network), `BalanceEntity`, `LastBlockHeightEntity`, `InitialSyncEntity` — foundational types used everywhere
- [x] **1.4 Token & Transaction Models** — `TokenAccount`, `MintAccount`, `FullTokenAccount`, `Transaction`, `FullTransaction`, `TokenTransfer`, `LastSyncedTransaction` — data layer types for storage and API surface
- [x] **1.5 MainStorage (GRDB)** — First database: schema + migrations for balance, last block height, initial sync flag. DAO methods for read/write. Follows EvmKit.Swift GRDB patterns
- [x] **1.6 TransactionStorage (GRDB)** — Second database: schema + migrations for transactions, token accounts, mint accounts, syncer state. Complex queries with optional filters (incoming, mint address), pagination (fromHash, limit)

### Phase 2: Network & Sync Infrastructure

- [x] **2.1 RPC Client — Base** — Generic `RpcClient` class: HsToolKit.NetworkManager (Alamofire, same as EvmKit/TonKit) + Codable, JSON-RPC 2.0 request/response envelope, error handling, `BufferInfo` adapter for Solana base64-encoded account data (custom Codable adapter, like Android's `BufferInfoJsonAdapter`)
- [x] **2.2 RPC Client — Endpoints** — Typed methods: `getBalance`, `getBlockHeight`, `getTokenAccountsByOwner`, `getSignaturesForAddress`, `getTransaction`, `sendTransaction`, `getLatestBlockhash`. Batch request support (chunked, used by TransactionSyncer). RPC provider: Alchemy only (same as Android `RpcSource.Alchemy`)
- [x] **2.3 ConnectionManager** — `NWPathMonitor`-based reachability: connected/disconnected state, Combine publisher, start/stop lifecycle
- [x] **2.4 ApiSyncer** — Timer-based block height polling: configurable interval from `RpcSource`, start/stop/pause/resume, fires delegate on new block height. Depends on `RpcClient` + `ConnectionManager`

### Phase 3: Business Logic — Core Sync

- [x] **3.1 BalanceManager** — Fetch SOL balance via RPC, cache in MainStorage, sync state tracking, Combine notification on change
- [x] **3.2 TokenAccountManager** — Fetch SPL token accounts via RPC, NFT vs fungible distinction, mint metadata enrichment, cache in TransactionStorage
- [x] **3.3 Jupiter Token Metadata + Metaplex NFT Detection** — `JupiterApiService`: REST client for Jupiter API (`api.jup.ag/tokens/v2/search`) for token metadata (name, symbol, decimals). Metaplex on-chain metadata via RPC (`nftClient.findAllByMintList()`) for NFT detection (decimals==0 && supply==1). Android uses Jupiter, NOT SolanaFM
- [x] **3.4 TransactionSyncer** — History sync: fetch signatures → fetch full transactions → parse pre/post balance changes → detect token transfers → resolve mint metadata → persist. Batch RPC. **Largest single component.** Android ref: `TransactionSyncer.kt` + `Extensions.kt` + `NftClient.kt`
- [x] **3.5 PendingTransactionSyncer** — Monitor unconfirmed transactions: poll by block height, re-broadcast same base64 tx if blockhash still valid, mark failed if expired
- [ ] **3.6 TransactionManager** — Aggregation layer: combine confirmed + pending txs, filter by SOL/SPL/direction, expose as publisher
- [ ] **3.7 SyncManager** — Central orchestrator: start/stop all syncers, coordinate listener callbacks, track initial sync completion, propagate sync state

### Phase 4: Facade & Signing

- [ ] **4.1 Kit Facade** — `Kit.swift`: static `Kit.instance(...)` factory with full DI, Combine publishers (`balancePublisher`, `syncStatePublisher`, `lastBlockHeightPublisher`, `tokenAccountsPublisher`, `transactionsPublisher`), `start()`/`stop()` lifecycle, `statusInfo()` for debugging
- [ ] **4.2 Signer & Key Derivation** — `Signer.swift`: Ed25519 keypair from mnemonic via HdWalletKit.Swift (BIP44 m/44'/501'/0', curve `.ed25519`) + TweetNaCl for Ed25519 signing. Reference: `TonKitManager.swift` in unstoppable-wallet-ios uses identical derivation pattern. Standalone — no reference to `Kit`
- [ ] **4.3 Transaction Serialization** — Implement from scratch in `Helper/SolanaSerializer.swift`, following EvmKit.Swift's `Helper/RLP.swift` pattern. Solana binary format: Message (header + account keys + recent blockhash + compiled instructions), compact-u16 arrays, Transaction (signatures + message). Serialize → `Data` for signing and broadcast. Android delegates to `sol4k` library — no equivalent in Swift, must be custom. Only legacy transactions in MVP; V0 versioned transactions deferred to Phase 6
- [ ] **4.4 Program Instructions — SystemProgram & TokenProgram** — Implement from scratch in `Programs/` directory. Android uses SolanaKT/metaplex library — no Swift equivalent, must be custom. `SystemProgram.transfer` (4-byte discriminator + u64 LE), `TokenProgram.transfer`/`transferChecked` (1-byte discriminator + u64 LE + optional u8 decimals), `AssociatedTokenAccountProgram.createIdempotent` (7 account keys, no data payload). Each builds `TransactionInstruction` structs fed into Transaction
- [ ] **4.5 Send SOL & SPL Token Transfers** — End-to-end pipeline (Android uses sol4k's `Action.serializeAndSendWithFee()` — we compose manually): build instructions → add ComputeBudget instructions → compose Transaction → fetch recent blockhash via RPC → serialize message → sign via Signer (TweetNaCl Ed25519) → prepend signatures → base64 encode → `sendTransaction` RPC. SOL transfer + SPL token transfer (with ATA creation if needed) as two public API methods on Kit
- [ ] **4.6 Priority Fees & Retry Logic** — `ComputeBudgetProgram` instructions for priority fees, transaction retry on expiry, fee estimation. Added later in Android (separate commit), non-MVP but important for reliability

### Phase 5: Extras (post-MVP)

- [ ] **5.1 V0 Versioned Transactions** — Extend serialization to support V0 transaction format (address lookup tables). Required for `sendRawTransaction()` API and Jupiter swaps. Android uses `sol4k.VersionedTransaction`
- [ ] **5.2 Jupiter Swap Integration** — `JupiterApiService`: DEX swap quotes, route building, swap transaction construction. Requires V0 versioned transactions (5.1). Optional feature from Android kit
- [ ] **5.3 TokenProvider** — Token information service for enriching token metadata beyond on-chain data

## Completed

| Milestone | Date |
|-----------|------|
