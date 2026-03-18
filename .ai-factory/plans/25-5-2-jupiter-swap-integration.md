# Plan: Jupiter Swap Integration

## Context

Add Jupiter DEX aggregator swap functionality to `JupiterApiService` — quote fetching, route building, and swap transaction construction via Jupiter's REST API. The existing `JupiterApiService` only handles token metadata lookup (`GET /tokens/v2/search`); this milestone extends it with the `/quote` and `/swap` endpoints. The swap transaction is returned as a base64-encoded V0 versioned transaction that callers sign and broadcast via `kit.sendRawTransaction()` (already implemented in 5.1). The Android kit does not have this feature — this is a new iOS-only addition.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Models

- [x] **Task 1: Add Jupiter swap Codable models**
  Files: `Sources/SolanaKit/Models/Jupiter/JupiterSwapModels.swift`
  Create a new file under `Models/Jupiter/` with all Codable structs needed for the Jupiter v6 swap API:

  **Quote response** (`JupiterQuoteResponse`): `public struct`, fields: `inputMint: String`, `inAmount: String`, `outputMint: String`, `outAmount: String`, `otherAmountThreshold: String`, `swapMode: String`, `slippageBps: Int`, `priceImpactPct: String`, `routePlan: [RoutePlan]`, `contextSlot: Int64?`, `timeTaken: Double?`. Nested `RoutePlan`: `swapInfo: SwapInfo`, `percent: Int`. Nested `SwapInfo`: `ammKey: String`, `label: String?`, `inputMint: String`, `outputMint: String`, `inAmount: String`, `outAmount: String`, `feeAmount: String`, `feeMint: String`. All fields from the Jupiter API — use optional types for fields that may be absent.

  **Swap request** (`JupiterSwapRequest`): `internal struct Encodable`, fields: `quoteResponse: JupiterQuoteResponse`, `userPublicKey: String`, `wrapAndUnwrapSol: Bool` (default `true`), `dynamicComputeUnitLimit: Bool` (default `true`), `dynamicSlippage: Bool?` (optional), `prioritizationFeeLamports: PrioritizationFee?`. Nested `PrioritizationFee`: `priorityLevelWithMaxLamports: PriorityLevelConfig`. Nested `PriorityLevelConfig`: `maxLamports: Int64`, `priorityLevel: String` (e.g. `"medium"`).

  **Swap response** (`JupiterSwapResponse`): `public struct`, fields: `swapTransaction: String` (base64-encoded versioned transaction), `lastValidBlockHeight: Int64`, `prioritizationFeeLamports: Int64?`, `computeUnitLimit: Int?`, `dynamicSlippageReport: DynamicSlippageReport?`. Nested `DynamicSlippageReport`: `slippageBps: Int?`, `otherAmount: String?`, `simulatedIncurredSlippageBps: Int?`.

  Mark `JupiterQuoteResponse` and `JupiterSwapResponse` as `public` (callers need them for fee estimation and UI display). Use `Codable` conformance throughout. Follow the existing model pattern in `Models/` — plain structs, no GRDB conformance (these are transient API types, not persisted).

### Phase 2: Service

- [x] **Task 2: Add quote and swap methods to JupiterApiService** (depends on Task 1)
  Files: `Sources/SolanaKit/Api/JupiterApiService.swift`
  Extend the existing `JupiterApiService` with two new methods:

  **`quote()`**: `func quote(inputMint: String, outputMint: String, amount: UInt64, slippageBps: Int) async throws -> JupiterQuoteResponse`
  - `GET https://api.jup.ag/swap/v1/quote`
  - Query parameters: `inputMint`, `outputMint`, `amount` (as string), `slippageBps`
  - Use `networkManager.fetchJson(url:method:.get:parameters:encoding:URLEncoding.queryString:headers:)` — same pattern as the existing `tokenInfo` method
  - Decode response JSON into `JupiterQuoteResponse`
  - Send `x-api-key` header if `apiKey` is set (same as `tokenInfo`)
  - Add `JupiterError.quoteNotAvailable` for empty/invalid responses

  **`swap()`**: `func swap(quoteResponse: JupiterQuoteResponse, userPublicKey: String, prioritizationMaxLamports: Int64? = nil) async throws -> JupiterSwapResponse`
  - `POST https://api.jup.ag/swap/v1/swap`
  - Build `JupiterSwapRequest` from the quote response + user public key
  - When `prioritizationMaxLamports` is provided, populate `prioritizationFeeLamports` field with a `PrioritizationFee` using `"medium"` priority level
  - Set `wrapAndUnwrapSol: true` and `dynamicComputeUnitLimit: true` as defaults
  - Since this is a POST with a JSON body, encode the `JupiterSwapRequest` using `JSONEncoder`, then use `URLSession.shared.data(for:)` directly (same pattern as `RpcApiProvider.fetchBatch` — `NetworkManager.fetchJson` doesn't handle Encodable bodies cleanly)
  - Decode the response into `JupiterSwapResponse`
  - Add `JupiterError.swapFailed(String)` for error responses

  Update the base URL handling: add a private `swapBaseUrl = URL(string: "https://api.jup.ag/swap/v1")!` alongside the existing `baseUrl` for the token search endpoint. The token search endpoint stays at its current URL.

- [x] **Task 3: Update IJupiterApiService protocol** (depends on Task 2)
  Files: `Sources/SolanaKit/Core/Protocols.swift`
  Add the two new method signatures to the `IJupiterApiService` protocol:
  ```swift
  func quote(inputMint: String, outputMint: String, amount: UInt64, slippageBps: Int) async throws -> JupiterQuoteResponse
  func swap(quoteResponse: JupiterQuoteResponse, userPublicKey: String, prioritizationMaxLamports: Int64?) async throws -> JupiterSwapResponse
  ```
  This ensures the service can be mocked for testing.

### Phase 3: Kit Integration

- [x] **Task 4: Expose Jupiter swap methods on Kit** (depends on Task 3)
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Add two new public methods to `Kit` that delegate to the internal `jupiterApiService`:

  **`jupiterQuote()`**: `public func jupiterQuote(inputMint: String, outputMint: String, amount: UInt64, slippageBps: Int) async throws -> JupiterQuoteResponse`
  - Delegates directly to `jupiterApiService.quote(...)`.
  - Pure pass-through — no additional logic needed in Kit.

  **`jupiterSwapTransaction()`**: `public func jupiterSwapTransaction(quoteResponse: JupiterQuoteResponse, prioritizationMaxLamports: Int64? = nil) async throws -> JupiterSwapResponse`
  - Calls `jupiterApiService.swap(quoteResponse: quoteResponse, userPublicKey: address, prioritizationMaxLamports: prioritizationMaxLamports)`.
  - Kit automatically provides `address` (the wallet's public key) as `userPublicKey` — callers don't need to pass it.
  - Returns the `JupiterSwapResponse` containing the base64-encoded versioned transaction.

  The caller's end-to-end swap flow will be:
  ```swift
  let quote = try await kit.jupiterQuote(inputMint: "So11...", outputMint: "EPjF...", amount: 1_000_000, slippageBps: 50)
  let swapResponse = try await kit.jupiterSwapTransaction(quoteResponse: quote)
  let rawTx = Data(base64Encoded: swapResponse.swapTransaction)!
  let fee = try Kit.estimateFee(rawTransaction: rawTx)  // already exists
  let result = try await kit.sendRawTransaction(rawTransaction: rawTx, signer: signer)  // already exists
  ```

  No new Combine publishers are needed — swap is a one-shot operation, not a stream. The resulting pending transaction is already tracked by `sendRawTransaction` → `PendingTransactionSyncer`.
