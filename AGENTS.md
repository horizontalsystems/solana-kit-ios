# AGENTS.md

> Project map for AI agents. Keep this file up-to-date as the project evolves.

## Project Overview

**SolanaKit** is a Swift Package that provides a complete Solana blockchain SDK for iOS/macOS — account/balance sync, SPL token accounts, transaction history, transaction sending, and HD wallet signing — exposing a Combine-based reactive API. It is a first-party dependency of `unstoppable-wallet-ios`.

## Tech Stack

- **Language:** Swift 5.9+
- **Package Manager:** SPM
- **Reactive:** Combine (`CurrentValueSubject`, `PassthroughSubject`)
- **Persistence:** GRDB.swift (two SQLite databases)
- **Networking:** URLSession + Codable (JSON-RPC 2.0)
- **Reachability:** NWPathMonitor
- **Key derivation:** HdWalletKit.Swift (BIP44, coin type 501)

## Target Project Structure

```
solana-kit-ios/
├── Package.swift                     # SPM manifest, declares SolanaKit target
├── Sources/
│   └── SolanaKit/
│       ├── Core/
│       │   ├── Kit.swift             # Public facade — Kit.instance() factory, Combine publishers
│       │   ├── Signer.swift          # Ed25519 signing, decoupled from Kit
│       │   ├── Protocols.swift       # Internal protocol definitions for DI
│       │   ├── SyncManager.swift     # Orchestrates sync subsystems
│       │   ├── BalanceManager.swift  # SOL balance fetch + publish
│       │   ├── TokenAccountManager.swift  # SPL token accounts
│       │   └── ConnectionManager.swift    # NWPathMonitor reachability
│       ├── Api/
│       │   ├── RpcClient.swift       # URLSession + Codable JSON-RPC 2.0 client
│       │   ├── ApiSyncer.swift       # Timer-based block height polling
│       │   └── SolanaFmService.swift # SolanaFM REST API (token metadata)
│       ├── Transactions/
│       │   ├── TransactionManager.swift
│       │   ├── TransactionSyncer.swift       # getSignaturesForAddress + getTransaction
│       │   └── PendingTransactionSyncer.swift # monitors unconfirmed txs
│       ├── Database/
│       │   ├── MainStorage.swift    # GRDB: BalanceEntity, LastBlockHeight, InitialSync
│       │   └── TransactionStorage.swift  # GRDB: Transaction, TokenTransfer, TokenAccount, etc.
│       └── Models/
│           ├── SyncState.swift      # enum: .synced / .syncing(progress) / .notSynced(error)
│           ├── RpcSource.swift      # RPC endpoint configuration
│           ├── FullTransaction.swift
│           ├── FullTokenAccount.swift
│           └── ...                  # other domain structs
├── Tests/
│   └── SolanaKitTests/
│       └── ...                      # unit tests (mocked RpcClient / storage)
└── iOS Example/                     # optional sample Xcode app
```

## Key Entry Points

| File | Purpose |
|------|---------|
| `Sources/SolanaKit/Core/Kit.swift` | Public API — instantiate, start/stop, subscribe to publishers |
| `Sources/SolanaKit/Core/Signer.swift` | HD derivation + Ed25519 signing (standalone) |
| `Sources/SolanaKit/Api/RpcClient.swift` | All Solana JSON-RPC calls |
| `Sources/SolanaKit/Database/MainStorage.swift` | GRDB main database access |
| `Sources/SolanaKit/Database/TransactionStorage.swift` | GRDB transaction database access |
| `Package.swift` | SPM manifest, external dependencies |

## Documentation

| Document | Path | Description |
|----------|------|-------------|
| Project spec | `.ai-factory/DESCRIPTION.md` | Full feature list, public API, DB schema, dependencies |
| Architecture | `.ai-factory/ARCHITECTURE.md` | Architecture decisions, folder rules, code conventions |
| Agent instructions | `CLAUDE.md` | Build commands, translation reference |

## AI Context Files

| File | Purpose |
|------|---------|
| `AGENTS.md` | This file — project structure map |
| `.ai-factory/DESCRIPTION.md` | Project specification, tech stack, public API |
| `.ai-factory/ARCHITECTURE.md` | Architecture pattern and guidelines |
| `CLAUDE.md` | Build commands, Kotlin→Swift translation table |

## Reference Projects (siblings)

| Path | Role |
|------|------|
| `../EvmKit.Swift/` | iOS pattern reference — mirror its structure |
| `../solana-kit-android/` | Source of truth for behaviour |
| `../unstoppable-wallet-ios/` | Integration target |
| `../unstoppable-wallet-android/` | Integration pattern reference |

## Available Skills

| Skill | When to use |
|-------|------------|
| `grdb` | GRDB queries, migrations, ValueObservation |
| `solana-rpc-swift` | Solana JSON-RPC in Swift (URLSession + Codable) |
| `swift-concurrency` | async/await, actors, TaskGroup, AsyncStream |
| `aif-plan` | Plan new feature implementation |
| `aif-implement` | Execute implementation plan |
| `aif-fix` | Debug and fix bugs |
| `aif-review` | Code review before PR |
