# Plan: 1.3 Core Models

## Context

Define the foundational value types and GRDB entities that every other layer depends on: `Address`, `SyncState`, `RpcSource`, `BalanceEntity`, `LastBlockHeightEntity`, and `InitialSyncEntity`. These live in the Models layer (no dependencies on other layers) and are imported by Core, Infrastructure, and the Kit facade.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Public Value Types

- [x] **Task 1: Address type**
  Files: `Sources/SolanaKit/Models/Address.swift`
  Create a `public struct Address` that wraps the existing `PublicKey`. Follow EvmKit's `Address.swift` pattern:
  - Store `public let publicKey: PublicKey` (the inner 32-byte key)
  - `public init(publicKey: PublicKey)` — direct init
  - `public init(_ base58String: String) throws` — convenience, delegates to `PublicKey(base58String)`
  - `public var base58: String` — returns `publicKey.base58`
  - Conform to `Equatable`, `Hashable` (delegate to `publicKey`)
  - Conform to `CustomStringConvertible` — `description` returns `base58`
  - Conform to GRDB `DatabaseValueConvertible` — store as blob via `publicKey.databaseValue`, reconstruct via `PublicKey.fromDatabaseValue`
  - Conform to `Codable` — encode/decode as Base58 string (delegate to `PublicKey`'s Codable)
  - Nested `enum ValidationError: Swift.Error` with case `invalidAddress` (for future validation needs)
  - Android ref: `solana-kit-android/.../models/Address.kt` — `data class Address(val publicKey: PublicKey)` with `toString() = publicKey.toBase58()`

- [x] **Task 2: SyncState enum**
  Files: `Sources/SolanaKit/Models/SyncState.swift`
  Create a `public enum SyncState` matching EvmKit's exact pattern:
  - Cases: `.synced`, `.syncing(progress: Double?)`, `.notSynced(error: Error)`
  - Manual `Equatable` conformance: `.synced == .synced`, `.syncing` compares progress, `.notSynced` compares errors via `"\(lhsError)" == "\(rhsError)"` (Error is not Equatable)
  - Convenience computed properties: `var synced: Bool`, `var syncing: Bool`, `var notSynced: Bool` (pattern-match each case)
  - `CustomStringConvertible` conformance for logging
  - Exact pattern source: `EvmKit.Swift/Sources/EvmKit/Models/SyncState.swift`
  - Android ref: `SolanaKit.kt` nested `sealed class SyncState { Synced, NotSynced(error), Syncing(progress) }`

- [x] **Task 3: SyncError types**
  Files: `Sources/SolanaKit/Models/SyncState.swift` (append to same file)
  Add a `public enum SyncError: Error` alongside `SyncState` in the same file:
  - `case notStarted` — sync has not been started yet
  - `case noNetworkConnection` — device is offline
  - Android ref: `SolanaKit.kt` — `open class SyncError : Exception() { class NotStarted, class NoNetworkConnection }`

- [x] **Task 4: RpcSource configuration type**
  Files: `Sources/SolanaKit/Models/RpcSource.swift`
  Create a `public struct RpcSource`:
  - `public let name: String` — human-readable provider name (e.g. "Alchemy")
  - `public let url: URL` — the JSON-RPC endpoint URL
  - `public let network: Network` — which Solana network (mainnet-beta, testnet, devnet)
  - `public let syncInterval: TimeInterval` — polling interval in seconds (default 30)
  - `public var isMainnet: Bool` computed property — `network == .mainnetBeta`
  - Define a nested `public enum Network: String` with cases `.mainnetBeta`, `.testnet`, `.devnet`
  - Static factory method in a `public extension`: `static func alchemy(apiKey: String) -> RpcSource` that returns `RpcSource(name: "Alchemy", url: URL("https://solana-mainnet.g.alchemy.com/v2/\(apiKey)")!, network: .mainnetBeta, syncInterval: 30)`
  - Android ref: `solana-kit-android/.../models/RpcSource.kt` — sealed class with `Alchemy(apiKey)` subclass, `syncInterval: Long = 30`, `endpoint.network.name == "mainnet-beta"` for `isMainnet`
  - EvmKit pattern ref: `EvmKit.Swift/.../Models/RpcSource.swift` — enum with static factory methods in extension

### Phase 2: GRDB Database Entities

- [x] **Task 5: BalanceEntity**
  Files: `Sources/SolanaKit/Models/BalanceEntity.swift`
  Create an `internal class BalanceEntity: Record` (GRDB `Record` subclass, following EvmKit's `AccountState` / `BlockchainState` pattern):
  - Table name: `"balances"`
  - Singleton-row pattern: `private static let primaryKey = "primaryKey"`, stored as a hardcoded string column (same as EvmKit's `BlockchainState`)
  - Property: `var lamports: Int64` — raw lamport balance (matches Android's `Long`)
  - Computed: `var balance: Decimal` — converts lamports to SOL (`Decimal(lamports) / 1_000_000_000`)
  - Inner `enum Columns: String, ColumnExpression` with cases `primaryKey`, `lamports`
  - `required init(row: Row) throws` — read `lamports` from row
  - `override func encode(to container:)` — write primaryKey + lamports
  - Convenience `init(lamports: Int64)` for creating new instances
  - Android ref: `BalanceEntity.kt` — `@Entity class BalanceEntity(val lamports: Long, @PrimaryKey val id: String = "")`
  - EvmKit pattern: `AccountState.swift` — `Record` subclass with singleton-row primaryKey pattern

- [x] **Task 6: LastBlockHeightEntity**
  Files: `Sources/SolanaKit/Models/LastBlockHeightEntity.swift`
  Create an `internal class LastBlockHeightEntity: Record` (GRDB `Record` subclass):
  - Table name: `"lastBlockHeights"`
  - Singleton-row pattern (same as `BalanceEntity`)
  - Property: `var height: Int64` — block height (matches Android's `Long`)
  - Inner `enum Columns: String, ColumnExpression` with cases `primaryKey`, `height`
  - `required init(row: Row) throws` + `override func encode(to:)`
  - Convenience `init(height: Int64)`
  - Android ref: `LastBlockHeightEntity.kt` — `@Entity class LastBlockHeightEntity(val height: Long, @PrimaryKey val id: String = "")`
  - EvmKit pattern: `BlockchainState.swift` — identical singleton-row `Record` pattern

- [x] **Task 7: InitialSyncEntity**
  Files: `Sources/SolanaKit/Models/InitialSyncEntity.swift`
  Create an `internal class InitialSyncEntity: Record` (GRDB `Record` subclass):
  - Table name: `"initialSyncs"`
  - Singleton-row pattern (same as others — only one sync-state per wallet DB)
  - Property: `var synced: Bool` — whether initial sync has completed
  - Inner `enum Columns: String, ColumnExpression` with cases `primaryKey`, `synced`
  - `required init(row: Row) throws` + `override func encode(to:)`
  - Convenience `init(synced: Bool)`
  - Android ref: `InitialSyncEntity.kt` — `@Entity class InitialSyncEntity(val initial: Boolean, @PrimaryKey val id: Long = 0)`
  - Note: Android uses auto-increment ID but only ever stores one row; simplify to the singleton-row primaryKey pattern for consistency with the other entities and EvmKit

## Commit Plan
- **Commit 1** (after tasks 1-4): "Add core value types: Address, SyncState, RpcSource"
- **Commit 2** (after tasks 5-7): "Add GRDB entities: BalanceEntity, LastBlockHeightEntity, InitialSyncEntity"
