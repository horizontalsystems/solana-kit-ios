# Architecture: Layered SDK with Facade Pattern

## Overview

SolanaKit uses a **layered architecture with a single public facade**. All external consumers interact exclusively through `Kit` (and the standalone `Signer`). Internally, the kit is divided into four horizontal layers: Public API, Core (orchestration + business logic), Infrastructure (networking + persistence), and Models (pure data types).

This pattern is the standard for the HorizontalSystems SDK family (EvmKit, BitcoinKit, etc.). It delivers clean separation of concerns, protocol-based testability, and a stable public surface that shields consumers from internal reorganization.

## Decision Rationale

- **Project type:** Pure Swift SDK library (no UI, no server)
- **Tech stack:** Swift 5.9+, Combine, GRDB, URLSession
- **Key factor:** Single consumer entry point (`Kit`) with Combine-based reactive state — the facade pattern maps perfectly to this API shape
- **Testability requirement:** Every subsystem behind a protocol so tests can inject mocks without touching networking or disk

## Folder Structure

```
Sources/SolanaKit/
│
├── Core/                          ← Business logic layer (depends on Infrastructure protocols only)
│   ├── Kit.swift                  ← Public facade: owns all subsystems, exposes Combine publishers
│   ├── Signer.swift               ← Public, standalone: HD derivation + Ed25519 signing
│   ├── Protocols.swift            ← Internal protocol definitions (IRpcClient, IMainStorage, etc.)
│   ├── SyncManager.swift          ← Orchestrates start/stop/refresh across all sync subsystems
│   ├── BalanceManager.swift       ← Fetches + persists SOL balance, publishes changes
│   ├── TokenAccountManager.swift  ← Fetches + persists SPL token accounts, publishes changes
│   └── ConnectionManager.swift    ← NWPathMonitor: publishes reachability, gates sync
│
├── Api/                           ← Network infrastructure (implements Core protocols)
│   ├── RpcClient.swift            ← Solana JSON-RPC 2.0 client (URLSession + Codable)
│   ├── ApiSyncer.swift            ← Timer loop: polls getSlot/getBlockHeight, notifies SyncManager
│   └── SolanaFmService.swift      ← SolanaFM REST client (token metadata)
│
├── Transactions/                  ← Transaction sync subsystem (Core-layer logic + Infra calls)
│   ├── TransactionManager.swift   ← Holds + publishes [FullTransaction], coordinates storage reads
│   ├── TransactionSyncer.swift    ← getSignaturesForAddress → getTransaction, incremental cursor
│   └── PendingTransactionSyncer.swift  ← Re-fetches unconfirmed txs until finalized
│
├── Database/                      ← Persistence infrastructure (implements Core protocols)
│   ├── MainStorage.swift          ← GRDB: BalanceEntity, LastBlockHeightEntity, InitialSyncEntity
│   └── TransactionStorage.swift   ← GRDB: Transaction, TokenTransfer, TokenAccount, MintAccount, LastSyncedTransaction
│
└── Models/                        ← Pure value types (no dependencies, imported by all layers)
    ├── SyncState.swift
    ├── RpcSource.swift
    ├── FullTransaction.swift
    ├── FullTokenAccount.swift
    ├── TransactionType.swift
    └── ...
```

## Layer Rules

```
Models          ← no dependencies (imported everywhere)
   ↑
Infrastructure  ← depends on Models only (RpcClient, MainStorage, TransactionStorage)
   ↑
Core            ← depends on Models + Infrastructure protocols (never concrete infra types)
   ↑
Kit (facade)    ← instantiates everything, wires Combine, exposes public API
```

### Dependency Rules

- ✅ Core may import Models
- ✅ Core may call through protocol interfaces defined in `Protocols.swift`
- ✅ Infrastructure types implement Core protocols
- ✅ `Kit.swift` instantiates concrete infra types and injects them into Core managers
- ❌ Core must NOT import concrete `RpcClient`, `MainStorage`, `TransactionStorage` directly
- ❌ Infrastructure must NOT import Core managers (no upward coupling)
- ❌ Models must NOT import any other layer
- ❌ Nothing outside `Kit.swift` and `Signer.swift` should be `public`

## Protocols (Interfaces)

Defined in `Core/Protocols.swift`. Every infrastructure type is accessed through a protocol:

```swift
// Core/Protocols.swift

protocol IRpcClient {
    func getBalance(address: String) async throws -> Decimal
    func getSlot() async throws -> Int
    func getSignaturesForAddress(address: String, before: String?, limit: Int) async throws -> [SignatureInfo]
    func getTransaction(signature: String) async throws -> RpcTransaction?
    func sendTransaction(_ serialized: String) async throws -> String
}

protocol IMainStorage {
    func balance(address: String) -> Decimal?
    func save(balance: Decimal, address: String) throws
    func lastBlockHeight() -> Int?
    func save(lastBlockHeight: Int) throws
    func initialSynced(address: String) -> Bool
    func setInitialSynced(address: String) throws
}

protocol ITransactionStorage {
    func transactions(fromSignature: String?, limit: Int?) -> [FullTransaction]
    func save(transactions: [Transaction]) throws
    func save(tokenTransfers: [TokenTransfer]) throws
    func lastSyncedSignature(address: String) -> String?
    func save(lastSyncedSignature: String, address: String) throws
}
```

## Combine Event Flow

All reactive state originates in the managers, propagates through `SyncManager`, and is published by `Kit`:

```
RpcClient (async)
    ↓ result
BalanceManager
    ↓ updates CurrentValueSubject<Decimal, Never>
SyncManager.balanceDidUpdate()
    ↓ fires PassthroughSubject
Kit.balanceSubject.send(newValue)      → Kit.balancePublisher (erased to AnyPublisher)
```

Rules:
- Managers own `CurrentValueSubject` for current value (survives subscription)
- Managers fire `PassthroughSubject` for events (no buffering needed)
- `Kit` exposes `.eraseToAnyPublisher()` — never exposes the underlying subject
- All `.send()` calls dispatched on `DispatchQueue.main`

## Kit Wiring (Composition Root)

`Kit.instance()` is the only place where concrete types are created and wired:

```swift
// Core/Kit.swift

public class Kit {
    // Internal subsystems — never exposed
    private let syncManager: SyncManager
    private let balanceManager: BalanceManager
    // ...

    // Public Combine publishers
    private let balanceSubject = CurrentValueSubject<Decimal, Never>(0)
    public var balancePublisher: AnyPublisher<Decimal, Never> {
        balanceSubject.eraseToAnyPublisher()
    }

    public static func instance(address: String, rpcSource: RpcSource, walletId: String) throws -> Kit {
        let mainStorage = try MainStorage(walletId: walletId)      // concrete type
        let txStorage = try TransactionStorage(walletId: walletId) // concrete type
        let rpcClient = RpcClient(rpcSource: rpcSource)            // concrete type

        let balanceManager = BalanceManager(
            address: address,
            rpcClient: rpcClient,     // injected as IRpcClient
            storage: mainStorage      // injected as IMainStorage
        )
        // ... wire everything
        return Kit(balanceManager: balanceManager, ...)
    }
}
```

## Signer — Intentional Decoupling

`Signer` is a public type but **never owned or referenced by `Kit`**. This mirrors EvmKit and is by design:

```swift
// Caller code (in unstoppable-wallet-ios)
let signer = try Signer(seed: mnemonic, coinType: 501)
let unsignedTx = try kit.buildTransferTransaction(to: recipient, lamports: amount)
let signedData = try signer.sign(transaction: unsignedTx)
try await kit.send(signedTransaction: signedData)
```

- `Signer` reads private key material — keeping it out of `Kit` limits key exposure surface
- `Kit` never touches key material; it only accepts pre-signed serialized bytes

## Database Pattern

Two separate GRDB databases, each behind its storage protocol:

```swift
// Database/MainStorage.swift
final class MainStorage: IMainStorage {
    private let dbQueue: DatabaseQueue

    init(walletId: String) throws {
        let url = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("solana-kit/main-\(walletId).sqlite")
        dbQueue = try DatabaseQueue(path: url.path)
        try migrate(dbQueue)
    }
}
```

GRDB entity types conform to `FetchableRecord & PersistableRecord & TableRecord`. Migrations are defined in a `DatabaseMigrator` configured at init time.

## Sync Lifecycle

```
kit.start()
    → ConnectionManager.start()          // begins NWPathMonitor
    → SyncManager.start()
        → ApiSyncer.start()              // starts timer loop
        → if connected: triggerSync()

ApiSyncer timer fires
    → getSlot() via IRpcClient
    → SyncManager.didUpdate(blockHeight:)
        → BalanceManager.sync()
        → TransactionSyncer.sync()
        → TokenAccountManager.sync()

ConnectionManager: offline
    → SyncManager.pause()               // stops active tasks
ConnectionManager: online
    → SyncManager.resume()              // triggers immediate sync
```

## Key Principles

1. **Single public entry point.** Only `Kit` and `Signer` are `public`. All managers, clients, and storage types are `internal`.

2. **Protocol-first.** Managers receive dependencies through protocols (`IRpcClient`, `IMainStorage`, etc.). No manager imports a concrete infrastructure type. This makes unit testing straightforward — inject mocks.

3. **Combine for state, async/await for operations.** Network calls and DB writes use `async throws func`. State changes flow through Combine subjects. Never mix: don't publish state synchronously inside an async call without dispatching to main.

4. **Main thread for publishers.** Every `.send()` on any subject must be dispatched on `DispatchQueue.main` to guarantee safe UI subscription.

5. **Incremental sync with cursors.** `TransactionSyncer` stores the last synced signature in `LastSyncedTransaction`. On restart, it resumes from that cursor. Never truncate and re-fetch the full history.

6. **Two databases, strict ownership.** `MainStorage` owns balance/sync-state records. `TransactionStorage` owns all transaction data. No cross-database joins or coupling.

## Code Examples

### Manager with Protocol Injection

```swift
// Core/BalanceManager.swift
final class BalanceManager {
    private let address: String
    private let rpcClient: IRpcClient          // protocol, not RpcClient
    private let storage: IMainStorage          // protocol, not MainStorage

    private let balanceSubject: CurrentValueSubject<Decimal, Never>

    init(address: String, rpcClient: IRpcClient, storage: IMainStorage,
         balanceSubject: CurrentValueSubject<Decimal, Never>) {
        self.address = address
        self.rpcClient = rpcClient
        self.storage = storage
        self.balanceSubject = balanceSubject

        // Restore last known balance immediately
        if let saved = storage.balance(address: address) {
            balanceSubject.send(saved)
        }
    }

    func sync() async {
        do {
            let balance = try await rpcClient.getBalance(address: address)
            try storage.save(balance: balance, address: address)
            DispatchQueue.main.async { [weak self] in
                self?.balanceSubject.send(balance)
            }
        } catch {
            // surface via SyncState, not a crash
        }
    }
}
```

### GRDB Entity

```swift
// Database/Models/BalanceEntity.swift
struct BalanceEntity: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "balances"

    var address: String
    var balance: String    // stored as String to avoid floating-point precision loss

    var decimalBalance: Decimal {
        Decimal(string: balance) ?? 0
    }
}
```

### Erased Publisher in Kit

```swift
// Core/Kit.swift (public API surface)
public class Kit {
    private let balanceSubject: CurrentValueSubject<Decimal, Never>

    // Consumers get AnyPublisher — they cannot call .send()
    public var balancePublisher: AnyPublisher<Decimal, Never> {
        balanceSubject.eraseToAnyPublisher()
    }

    // Synchronous accessor — returns last known value immediately
    public var balance: Decimal {
        balanceSubject.value
    }
}
```

### Unit Test with Mock

```swift
// Tests/SolanaKitTests/BalanceManagerTests.swift
final class BalanceManagerTests: XCTestCase {
    func testSyncUpdatesBalance() async throws {
        let mockRpc = MockRpcClient(getBalanceResult: 1_000_000)
        let mockStorage = MockMainStorage()
        let subject = CurrentValueSubject<Decimal, Never>(0)

        let manager = BalanceManager(
            address: "FakeAddress",
            rpcClient: mockRpc,
            storage: mockStorage,
            balanceSubject: subject
        )

        await manager.sync()

        XCTAssertEqual(subject.value, Decimal(1_000_000))
        XCTAssertEqual(mockStorage.savedBalance, Decimal(1_000_000))
    }
}
```

## Anti-Patterns

- ❌ **Accessing `RpcClient` directly from a manager** — always go through `IRpcClient` protocol
- ❌ **Making managers or storage classes `public`** — only `Kit` and `Signer` are public
- ❌ **Holding a reference to `Kit` inside any subsystem** — managers must not call back up to the facade
- ❌ **Publishing on a background thread** — all `.send()` calls must be on `DispatchQueue.main`
- ❌ **Fetching full transaction history on each sync** — always use the signature cursor in `LastSyncedTransaction`
- ❌ **Cross-database queries** — `MainStorage` and `TransactionStorage` are independent; join data in memory if needed
- ❌ **Putting signing logic in `Kit`** — `Signer` is intentionally separate; `Kit.send()` accepts only pre-signed bytes
