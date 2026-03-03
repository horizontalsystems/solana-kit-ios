# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Context

This is a **Swift Package under active construction**. The goal is to port `solana-kit-android` (Kotlin) to iOS Swift, following `EvmKit.Swift` as the structural reference. The parent workspace at `../CLAUDE.md` contains the full porting map and integration plan — read it before making architectural decisions.

Reference projects (all siblings of this directory):
- `../solana-kit-android/` — source of truth for behaviour
- `../EvmKit.Swift/` — source of truth for Swift patterns and project structure
- `../unstoppable-wallet-ios/` — integration target once the kit is complete

## Build Commands

```bash
# Build the package
swift build

# Run tests
swift test

# Resolve / update dependencies
swift package resolve
swift package update

# Open in Xcode
open Package.swift
```

## Target Architecture

### Package structure (mirrors EvmKit.Swift)
```
Package.swift
Sources/SolanaKit/
    Core/
        Kit.swift            ← public facade, Kit.instance() factory
        Signer.swift         ← separate from Kit; Ed25519 signing
        Protocols.swift      ← internal protocol definitions
        SyncManager.swift
        BalanceManager.swift
        TokenAccountManager.swift
        ConnectionManager.swift   ← NWPathMonitor (replaces Android NetworkCallback)
    Api/
        ApiSyncer.swift      ← timer-based block height polling
        RpcClient.swift      ← URLSession + Codable JSON-RPC
    Transactions/
        TransactionManager.swift
        TransactionSyncer.swift
        PendingTransactionSyncer.swift
    Database/
        MainStorage.swift    ← GRDB, stores balance / last block height / initial sync flag
        TransactionStorage.swift  ← GRDB, stores transactions / token transfers / token accounts
    Models/
        ...                  ← structs mirroring Android data classes
iOS Example/                 ← optional sample Xcode project
```

### Entry point: `Kit.swift`
Public facade instantiated via `Kit.instance(address:rpcSource:walletId:)`. Owns all subsystems. Wires internal events to Combine publishers. Lifecycle: `start()` / `stop()` / `refresh()` / `pause()` / `resume()`.

Public Combine API on `Kit`:
```swift
var lastBlockHeightPublisher: AnyPublisher<Int, Never>
var syncStatePublisher: AnyPublisher<SyncState, Never>          // SOL balance sync
var tokenBalanceSyncStatePublisher: AnyPublisher<SyncState, Never>
var transactionsSyncStatePublisher: AnyPublisher<SyncState, Never>
var balancePublisher: AnyPublisher<Decimal, Never>
var fungibleTokenAccountsPublisher: AnyPublisher<[FullTokenAccount], Never>
var transactionsPublisher: AnyPublisher<[FullTransaction], Never>
```

`SyncState` is an enum (not sealed class) with cases `.synced`, `.syncing(progress: Double?)`, `.notSynced(error: Error)`.

### Signer.swift
Separate from `Kit` (EvmKit pattern). Initialized from a mnemonic seed via `HdWalletKit.Swift` (BIP44, coin type 501). Signs transactions using Ed25519. `Kit` has no signing capability — callers pass a signed transaction back to `kit.sendSol(...)` / `kit.sendSpl(...)`.

### Database layer
Two GRDB databases stored under `Application Support/solana-kit/`:
- `main-<walletId>` — `BalanceEntity`, `LastBlockHeightEntity`, `InitialSyncEntity`
- `transactions-<walletId>` — `Transaction`, `TokenTransfer`, `TokenAccount`, `MintAccount`, `LastSyncedTransaction`

Use `MainStorage` and `TransactionStorage` as the only access points. Follow EvmKit's `ApiStorage` / `TransactionStorage` patterns.

### Networking
- Solana JSON-RPC via `URLSession` + `Codable`. No Retrofit/OkHttp equivalent needed.
- `ApiSyncer` polls `getSlot` (or `getBlockHeight`) on a timer; reachability-aware via `ConnectionManager`.
- `TransactionSyncer` calls `getSignaturesForAddress` + `getTransaction`.
- `SolanaFmService` hits the SolanaFM REST API for token metadata.

### Key Kotlin → Swift translations
| Kotlin | Swift |
|--------|-------|
| `sealed class SyncState` | `enum SyncState` with associated values |
| `data class Foo` | `struct Foo: Codable` |
| `suspend fun` | `async throws func` |
| `coroutineScope.launch` | `Task { }` |
| `StateFlow<T>` | `CurrentValueSubject<T, Never>` |
| `SharedFlow<T>` | `PassthroughSubject<T, Never>` |
| `ISyncListener` callback interface | Combine `PassthroughSubject` fired in `Kit` |
| Room `@Entity` / `@Dao` | GRDB `FetchableRecord` / `PersistableRecord` |
| `sol4k` keypair + signing | Ed25519 (TweetNaCl Swift port or `solana-swift`) |
| `hd-wallet-kit-android` | `HdWalletKit.Swift` (coin type 501 for Solana) |
| Moshi / Gson | `Codable` + `JSONDecoder` |

### SPM dependencies (expected)
- `GRDB.swift` — local persistence (same as EvmKit)
- `HdWalletKit.Swift` — BIP44 key derivation (same org)
- `HsToolKit.Swift` — networking utilities / logger (same org, used by EvmKit)
- `HsExtensions.Swift` — Swift extensions (same org)
- Ed25519 signing library — TBD (evaluate `solana-swift` or a TweetNaCl port)
