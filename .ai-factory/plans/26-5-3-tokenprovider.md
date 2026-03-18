# Plan: 5.3 TokenProvider

## Context

Create a public `TokenProvider` class that fetches SPL token metadata (name, symbol, decimals) from the Jupiter API for arbitrary mint addresses. This is the iOS port of Android's `TokenProvider.kt` — a thin wrapper around `JupiterApiService.tokenInfo()` exposed publicly so the wallet's "Add Token" flow can look up metadata for user-entered mint addresses. The kit already has `JupiterApiService` and `TokenInfo` internally; this milestone makes them accessible from outside the kit.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Public API Surface

- [x] **Task 1: Make `TokenInfo` public**
  Files: `Sources/SolanaKit/Models/TokenInfo.swift`
  Change `struct TokenInfo` from `internal` (implicit) to `public`. Mark all three properties (`name`, `symbol`, `decimals`) as `public let`. This struct is the return type consumed by wallet-layer code (e.g. `AddSolanaTokenBlockchainService`). Mirrors Android's `TokenInfo.kt` data class which is public. No other changes to the struct.

- [x] **Task 2: Create `TokenProvider` class** (depends on Task 1)
  Files: `Sources/SolanaKit/Core/TokenProvider.swift`
  Create a new `public` class `TokenProvider` with:
  - A private `jupiterApiService: IJupiterApiService` dependency
  - Public initializer: `public init(networkManager: NetworkManager, apiKey: String? = nil)` — internally creates a `JupiterApiService` instance from the provided `NetworkManager` and optional API key. This matches the Android wallet pattern where `TokenProvider(JupiterApiService(apiKey))` is constructed externally by the wallet.
  - One public async method: `public func tokenInfo(mintAddress: String) async throws -> TokenInfo` — delegates to `jupiterApiService.tokenInfo(mintAddress:)`.
  - This is intentionally a thin wrapper (matching Android's 9-line `TokenProvider.kt`). It exists as a separate public type because `JupiterApiService` is internal and the wallet needs a clean entry point for on-demand token metadata lookup without a `Kit` instance.

- [x] **Task 3: Add static convenience on `Kit`** (depends on Task 2)
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Add a public static method matching the EVM kit pattern (`Eip20Kit.Kit.tokenInfo(networkManager:rpcSource:contractAddress:)`):
  ```swift
  public static func tokenInfo(networkManager: NetworkManager, apiKey: String? = nil, mintAddress: String) async throws -> TokenInfo
  ```
  Internally creates a `JupiterApiService` and calls `tokenInfo(mintAddress:)`. This is a stateless convenience — no `Kit` instance required. It provides an alternative entry point for callers who prefer the static-method pattern over instantiating `TokenProvider`. Keep `JupiterApiService.JupiterError` as the thrown error type (already defined, includes `.tokenNotFound` and `.invalidResponse`).

- [x] **Task 4: Export `JupiterApiService.JupiterError` publicly**
  Files: `Sources/SolanaKit/Api/JupiterApiService.swift`
  The `JupiterError` enum nested inside `JupiterApiService` is currently `internal`. Make it `public` so wallet-layer callers of `TokenProvider.tokenInfo(...)` or `Kit.tokenInfo(...)` can catch specific error cases (especially `.tokenNotFound(mintAddress:)` to display a "token not found" message in the Add Token UI). Change `enum JupiterError: Error` to `public enum JupiterError: Error` and ensure all cases are accessible. Follow the existing pattern where `SendError` in `Kit.swift` is already public.
