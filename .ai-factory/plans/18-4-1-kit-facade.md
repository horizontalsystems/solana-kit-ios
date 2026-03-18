# Plan: Kit Facade

## Context

The Kit.swift facade is already ~95% implemented: factory method with full DI, all 7 Combine publishers, lifecycle methods, delegate conformance, synchronous accessors, and transaction query APIs are all present. This milestone completes the facade by adding the missing `statusInfo()` debugging method, public metadata properties (`address`, `isMainnet`), the `Kit.clear(walletId:)` static cleanup method, and Solana-specific constants — matching both the Android `SolanaKit.kt` companion object and the EvmKit.Swift `Kit.swift` pattern.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Public metadata properties

- [x] **Task 1: Add `address` and `isMainnet` public properties to Kit**
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Add two stored public properties to `Kit`: `public let address: String` (the Base58-encoded wallet address) and `public let isMainnet: Bool` (derived from `rpcSource.isMainnet` at construction time). In the private `init`, accept and assign both. In `Kit.instance(...)`, pass `address` and `rpcSource.isMainnet` to the initializer. Follow EvmKit's pattern where `Kit` exposes `public let address: Address` and `public let chain: Chain` (see `EvmKit.Swift/Sources/EvmKit/Core/Kit.swift` lines 26-28). Android exposes `receiveAddress` (derived from `address.publicKey.toBase58()`) and `isMainnet` (derived from `rpcSource.endpoint.network`).

### Phase 2: Debugging & cleanup API

- [x] **Task 2: Implement `statusInfo()` method**
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Add a `public func statusInfo() -> [(String, Any)]` method that returns a diagnostic tuple array. Include: `"Last Block Height"` (from `lastBlockHeightSubject.value`, formatted as String or "N/A" if 0), `"Sync State"` (from `syncStateSubject.value.description`), `"Token Sync State"` (from `tokenBalanceSyncStateSubject.value.description`), `"Transactions Sync State"` (from `transactionsSyncStateSubject.value.description`), `"RPC Source"` (from `rpcApiProvider.source`). Follow EvmKit's `statusInfo()` pattern (`Kit.swift` line 250-257) and Android's `statusInfo()` which returns `mapOf("Last Block Height" to lastBlockHeight, "Sync State" to syncState)`. Store a reference to `rpcApiProvider` (or just its `source` string) in Kit's init so the RPC source name is accessible for status reporting.

- [x] **Task 3: Implement `Kit.clear(walletId:)` static method** (depends on Task 1)
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Add a `public static func clear(walletId: String) throws` method that deletes both GRDB databases for the given wallet. Call `MainStorage.clear(walletId: walletId)` and `TransactionStorage.clear(walletId: walletId)` — both static methods already exist in the storage classes (see `MainStorage.swift` line 82 and `TransactionStorage.swift` line 126). Follow EvmKit's `Kit.clear(exceptFor:)` pattern. Android equivalent: `SolanaKit.clear(context, walletId)` which deletes both Room databases.

### Phase 3: Solana-specific constants

- [x] **Task 4: Add public constants to Kit**
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Add static constants matching Android's `SolanaKit.Companion` object: `public static let baseFeeLamports: Int64 = 5000` (base transaction fee in lamports), `public static let fee: Decimal = Decimal(string: "0.000155")!` (approximate fee in SOL for UI display), `public static let accountRentAmount: Decimal = Decimal(string: "0.001")!` (minimum SOL to keep an account alive). Place these at the top of the class body, after the class declaration, before stored properties — matching EvmKit's `public static let defaultGasLimit = 21000` placement.
