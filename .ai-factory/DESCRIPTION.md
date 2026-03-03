# Project: SolanaKit iOS

## Overview

**SolanaKit** is a native Swift Package that provides a complete Solana blockchain SDK for iOS and macOS. It handles all Solana protocol concerns — account/balance sync, SPL token accounts, transaction history, transaction sending, and HD wallet key derivation — exposing a clean, reactive Combine-based API to wallet applications.

The kit is designed as a dependency of `unstoppable-wallet-ios` (a multi-chain non-custodial wallet), following the same architecture pattern as `EvmKit.Swift` from the same organization.

## Core Features

- **SOL balance sync** — polls block height, fetches native balance via JSON-RPC
- **SPL token account sync** — discovers and tracks all fungible token accounts for an address
- **Transaction history** — fetches, decodes, and persists full transaction history (SOL transfers + SPL token transfers)
- **Pending transaction tracking** — monitors unconfirmed transactions until finalized
- **Transaction sending** — serializes and broadcasts signed SOL/SPL transactions
- **Ed25519 signing** — BIP44 (coin type 501) HD key derivation + Ed25519 signing via `Signer`, decoupled from `Kit`
- **Network-aware sync** — pauses sync when offline, resumes on reconnect via `NWPathMonitor`
- **GRDB persistence** — two SQLite databases (main + transactions), survives restarts with incremental sync
- **Combine API** — all state changes emitted as `AnyPublisher` streams

## Tech Stack

- **Language:** Swift 5.9+
- **Package Manager:** Swift Package Manager (SPM)
- **Reactive layer:** Combine (`CurrentValueSubject`, `PassthroughSubject`, `AnyPublisher`)
- **Persistence:** GRDB.swift (SQLite, two databases)
- **Networking:** URLSession + Codable (JSON-RPC 2.0 over HTTPS)
- **Reachability:** Network.framework `NWPathMonitor`
- **Key derivation:** HdWalletKit.Swift (BIP44, coin type 501)
- **Signing:** Ed25519 (TweetNaCl Swift port or solana-swift — TBD)
- **Utilities:** HsToolKit.Swift (Logger, BackgroundModeObserver), HsExtensions.Swift

## Architecture

See `.ai-factory/ARCHITECTURE.md` for detailed architecture guidelines.
**Pattern:** Layered SDK with Facade Pattern

Summary — layered architecture with a single public facade (`Kit`):

```
Kit (public facade)
 ├── SyncManager          — orchestrates all sync subsystems
 ├── BalanceManager       — SOL balance state + persistence
 ├── TokenAccountManager  — SPL token accounts state + persistence
 ├── TransactionManager   — transaction records + Combine emission
 ├── ApiSyncer            — block height polling loop
 ├── TransactionSyncer    — signature history + getTransaction fetch
 ├── PendingTransactionSyncer — monitors unconfirmed transactions
 ├── ConnectionManager    — NWPathMonitor reachability
 ├── RpcClient            — Solana JSON-RPC 2.0 over URLSession
 ├── SolanaFmService      — SolanaFM REST API (token metadata)
 ├── MainStorage          — GRDB main database
 └── TransactionStorage   — GRDB transaction database
```

`Signer` is a separate public type, never owned by `Kit`. Callers create a `Signer` from mnemonic, use it to sign a transaction, then pass the serialized signed bytes to `kit.send(...)`.

## Public API

```swift
// Instantiation
let kit = try Kit.instance(address: pubKey, rpcSource: rpcSource, walletId: id)

// Lifecycle
kit.start()
kit.stop()
kit.refresh()

// Reactive state
kit.lastBlockHeightPublisher          // AnyPublisher<Int, Never>
kit.syncStatePublisher                // AnyPublisher<SyncState, Never>
kit.tokenBalanceSyncStatePublisher    // AnyPublisher<SyncState, Never>
kit.transactionsSyncStatePublisher    // AnyPublisher<SyncState, Never>
kit.balancePublisher                  // AnyPublisher<Decimal, Never>
kit.fungibleTokenAccountsPublisher    // AnyPublisher<[FullTokenAccount], Never>
kit.transactionsPublisher             // AnyPublisher<[FullTransaction], Never>

// Queries
kit.transactions(fromHash:limit:)
kit.fungibleTokenAccounts()
kit.balance

// Sending
kit.send(signedTransaction: Data) async throws

// Signing (separate)
let signer = try Signer(seed: mnemonic)
let signed = try signer.sign(transaction: unsignedTx)
```

## Database Schema

**MainDatabase** (`main-<walletId>.sqlite`):
- `BalanceEntity` — lamports balance
- `LastBlockHeightEntity` — last known block height
- `InitialSyncEntity` — flag per address for initial sync completion

**TransactionDatabase** (`transactions-<walletId>.sqlite`):
- `Transaction` — raw transaction record (signature, blockTime, slot, type, etc.)
- `TokenTransfer` — SPL token transfer detail (mint, source, destination, amount)
- `TokenAccount` — SPL token account state (mint, owner, amount)
- `MintAccount` — token mint metadata (decimals, supply)
- `LastSyncedTransaction` — cursor for incremental transaction sync

## SPM Dependencies

```swift
// Package.swift
.package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
.package(url: "https://github.com/horizontalsystems/HdWalletKit.Swift", from: "1.0.0"),
.package(url: "https://github.com/horizontalsystems/HsToolKit.Swift", from: "2.0.0"),
.package(url: "https://github.com/horizontalsystems/HsExtensions.Swift", from: "1.0.0"),
// Ed25519 signing: TBD (solana-swift, tweetnacl-swift, or swift-crypto)
```

## Integration Target

Once complete, `solana-kit-ios` will be integrated into `unstoppable-wallet-ios` via:
- `SolanaKitManager.swift` — lifecycle, per-wallet `Kit` instances
- `SolanaAdapter.swift` — conforms to `IBalanceAdapter`, `IDepositAdapter`
- `SolanaTransactionsAdapter.swift` — conforms to `ITransactionsAdapter`
- `SolanaTransactionConverter.swift` — maps `FullTransaction` to wallet's `TransactionRecord`

## Non-Functional Requirements

- **Incremental sync:** never re-fetches the full history, uses signature cursors
- **Offline resilience:** state survives app restarts via GRDB; sync resumes on reconnect
- **Testability:** all subsystems are protocol-backed for mock injection
- **No UI:** pure SDK, no SwiftUI/UIKit dependencies
- **Thread safety:** all published state changes dispatched on `DispatchQueue.main`
