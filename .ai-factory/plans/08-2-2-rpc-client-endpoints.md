# Plan: RPC Client — Endpoints

## Context

Implement typed JSON-RPC method subclasses for all Solana RPC endpoints needed by the kit (`getBalance`, `getBlockHeight`, `getTokenAccountsByOwner`, `getSignaturesForAddress`, `getTransaction`, `sendTransaction`, `getLatestBlockhash`), plus batch request support on `RpcApiProvider` for chunked `getTransaction` calls used by `TransactionSyncer`. Also add `getMultipleAccounts` which the Android kit uses extensively for token balance refresh and mint metadata fetch.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: RPC Response Models

- [x] **Task 1: RPC response model structs for transaction data**
  Files: `Sources/SolanaKit/Models/Rpc/RpcTransactionResponse.swift`
  Create `Codable` structs mirroring the Android `TransactionModels.kt`:
  - `RpcTransactionResponse` — top-level: `blockTime: Int64?`, `meta: RpcTransactionMeta?`, `slot: Int64?`, `transaction: RpcTransactionDetail?`
  - `RpcTransactionMeta` — `err: AnyCodable?`, `fee: Int64`, `preBalances: [Int64]`, `postBalances: [Int64]`, `preTokenBalances: [RpcTokenBalance]?`, `postTokenBalances: [RpcTokenBalance]?`
  - `RpcTokenBalance` — `accountIndex: Int`, `mint: String`, `owner: String?`, `uiTokenAmount: RpcUiTokenAmount?`
  - `RpcUiTokenAmount` — `amount: String`, `decimals: Int`, `uiAmountString: String?`
  - `RpcTransactionDetail` — `message: RpcTransactionMessage?`
  - `RpcTransactionMessage` — `accountKeys: [RpcAccountKey]?`
  - `RpcAccountKey` — `pubkey: String`, `signer: Bool?`, `writable: Bool?`
  For `err` field (which is `Any?` in Android), use a small `AnyCodable` wrapper or decode as `AnyDecodable` that stores the raw value and exposes a string description. This field is only used to check `!= nil` (error present) and convert to string.

- [x] **Task 2: RPC response model for signature info**
  Files: `Sources/SolanaKit/Models/Rpc/SignatureInfo.swift`
  Create `SignatureInfo: Codable` struct matching Android's:
  - `err: AnyCodable?` (nullable, checked for presence only)
  - `memo: String?`
  - `signature: String`
  - `slot: Int64?`
  - `blockTime: Int64?`

- [x] **Task 3: RPC response model for latest blockhash**
  Files: `Sources/SolanaKit/Models/Rpc/RpcBlockhashResponse.swift`
  Create `RpcBlockhashResponse: Codable` — the `value` object returned by `getLatestBlockhash`:
  - `blockhash: String`
  - `lastValidBlockHeight: Int64`
  The actual RPC response wraps this in `{"context":...,"value":{...}}`, so also create a generic `RpcResultResponse<T: Decodable>: Decodable` wrapper with `context: RpcContext?` and `value: T`, where `RpcContext` has `slot: Int64`. This wrapper is reused by `getBalance` and `getTokenAccountsByOwner` too.

### Phase 2: Typed JsonRpc Subclasses

Each subclass lives in `Sources/SolanaKit/Api/JsonRpc/` following the EvmKit one-file-per-method pattern. Each overrides `parse(result:)` to decode the raw `Any` result into a typed Swift value via `JSONSerialization.data(withJSONObject:)` + `JSONDecoder`.

- [x] **Task 4: GetBalanceJsonRpc**
  Files: `Sources/SolanaKit/Api/JsonRpc/GetBalanceJsonRpc.swift`
  `JsonRpc<Int64>` subclass. Method: `"getBalance"`. Params: `[address, ["commitment": "confirmed"]]`.
  The result is a `{"context":...,"value":<lamports>}` object. Parse by extracting `value` as `Int64` from the result dict. Reference: Android uses `rpcClient.getBalance(publicKey)` which returns `Long` (lamports).

- [x] **Task 5: GetBlockHeightJsonRpc**
  Files: `Sources/SolanaKit/Api/JsonRpc/GetBlockHeightJsonRpc.swift`
  `JsonRpc<Int64>` subclass. Method: `"getBlockHeight"`. No extra params.
  Result is a bare integer. Parse by casting `result as? Int` then `Int64(...)`, or handle `NSNumber`.

- [x] **Task 6: GetTokenAccountsByOwnerJsonRpc**
  Files: `Sources/SolanaKit/Api/JsonRpc/GetTokenAccountsByOwnerJsonRpc.swift`
  `JsonRpc<[RpcKeyedAccount]>` subclass. Method: `"getTokenAccountsByOwner"`. Params: `[ownerAddress, ["programId": TokenProgram.PROGRAM_ID], ["encoding": "jsonParsed"]]`.
  Result is `{"context":...,"value":[{"pubkey":"...","account":{...}},...]}`. Create `RpcKeyedAccount: Codable` with `pubkey: String` and `account: RpcParsedAccountData` (nested parsed token account info with `mint`, `owner`, `tokenAmount`). Place the `RpcKeyedAccount` model in a new file `Sources/SolanaKit/Models/Rpc/RpcKeyedAccount.swift` or inline in this file.
  Parse by extracting `value` array from result dict, serializing to Data, decoding via `JSONDecoder`.

- [x] **Task 7: GetSignaturesForAddressJsonRpc**
  Files: `Sources/SolanaKit/Api/JsonRpc/GetSignaturesForAddressJsonRpc.swift`
  `JsonRpc<[SignatureInfo]>` subclass. Method: `"getSignaturesForAddress"`. Params: `[address, configDict]` where `configDict` optionally includes `limit`, `before`, `until` (omit nil keys). Reference: Android's `ConfirmedSignFAddr2(limit, before, until)`.
  Init: `init(address: String, limit: Int? = nil, before: String? = nil, until: String? = nil)`.
  Result is a JSON array of signature info objects. Parse by serializing to Data, decoding `[SignatureInfo]`.

- [x] **Task 8: GetTransactionJsonRpc**
  Files: `Sources/SolanaKit/Api/JsonRpc/GetTransactionJsonRpc.swift`
  `JsonRpc<RpcTransactionResponse?>` subclass (optional — transaction may not exist). Method: `"getTransaction"`. Params: `[signature, ["encoding": "jsonParsed", "maxSupportedTransactionVersion": 0]]`. Matches Android batch request params exactly.
  Parse by serializing result to Data, decoding `RpcTransactionResponse`.

- [x] **Task 9: SendTransactionJsonRpc**
  Files: `Sources/SolanaKit/Api/JsonRpc/SendTransactionJsonRpc.swift`
  `JsonRpc<String>` subclass. Method: `"sendTransaction"`. Params: `[base64EncodedTransaction, ["encoding": "base64", "skipPreflight": false, "preflightCommitment": "confirmed", "maxRetries": 0]]`. Matches Android's `PendingTransactionSyncer.sendTransaction` params.
  Result is a transaction signature string. Parse by casting `result as? String`.

- [x] **Task 10: GetLatestBlockhashJsonRpc**
  Files: `Sources/SolanaKit/Api/JsonRpc/GetLatestBlockhashJsonRpc.swift`
  `JsonRpc<RpcBlockhashResponse>` subclass. Method: `"getLatestBlockhash"`. Params: `[["commitment": "finalized"]]`. Reference: Android uses `connection.getLatestBlockhashExtended(Commitment.FINALIZED)`.
  Result is `{"context":...,"value":{"blockhash":"...","lastValidBlockHeight":...}}`. Parse by extracting `value` from result dict, serializing to Data, decoding `RpcBlockhashResponse`.

- [x] **Task 11: GetMultipleAccountsJsonRpc**
  Files: `Sources/SolanaKit/Api/JsonRpc/GetMultipleAccountsJsonRpc.swift`
  `JsonRpc<[BufferInfo?]>` subclass. Method: `"getMultipleAccounts"`. Params: `[addressArray, ["encoding": "base64"]]`.
  Result is `{"context":...,"value":[...]}` where each element is a `BufferInfo` or `null`. Parse by extracting `value` array, serializing to Data, decoding `[BufferInfo?]`.
  This is used by `TokenAccountManager` (to refresh token balances via `AccountInfo` data) and `TransactionSyncer` (to fetch `Mint` data for decimals/supply). The existing `BufferInfo` model already handles the base64 data decoding.

### Phase 3: Batch Request Support

- [x] **Task 12: Add batch fetch method to RpcApiProvider**
  Files: `Sources/SolanaKit/Api/RpcApiProvider.swift`, `Sources/SolanaKit/Core/Protocols.swift`
  Add a `fetchBatch<T>(rpcs: [JsonRpc<T>]) async throws -> [T?]` method to `RpcApiProvider`:
  1. Build a JSON array of request dicts: `rpcs.enumerated().map { rpc.parameters(id: $0.offset) }` — each with sequential `id` starting at 0.
  2. Serialize the array to JSON Data via `JSONSerialization`.
  3. POST to `self.url` using `networkManager.fetchData(url:method:parameters:encoding:headers:interceptor:)` — or use a raw `URLRequest` via `networkManager` if Alamofire's parameter encoding doesn't support raw JSON arrays. Alternative: use `URLSession` directly for this one method (Alamofire's `JSONEncoding` expects a dict, not an array). Build `URLRequest` manually: set `httpMethod = "POST"`, `httpBody = jsonArrayData`, `Content-Type: application/json`, add auth headers.
  4. Parse the response: `JSONSerialization.jsonObject(with:)` → cast to `[[String: Any]]`, sort by `id`, for each element create `JsonRpcResponse.response(jsonObject:)`, call `rpc.parse(response:)`.
  5. Return `[T?]` where `nil` entries correspond to items with null result or parse failures (matches Android's skip-on-error behavior).
  Add `fetchBatch<T>(rpcs: [JsonRpc<T>]) async throws -> [T?]` to the `IRpcApiProvider` protocol.

- [x] **Task 13: Add chunked batch convenience for getTransaction**
  Files: `Sources/SolanaKit/Api/RpcApiProvider.swift`
  Add a convenience method `fetchTransactionsBatch(signatures: [String]) async throws -> [String: RpcTransactionResponse]` that:
  1. Creates `GetTransactionJsonRpc` for each signature.
  2. Chunks the array into groups of 100 (`batchChunkSize`), matching Android's `TransactionSyncer.batchChunkSize = 100`.
  3. For each chunk, calls `fetchBatch(rpcs:)`.
  4. Collects results into a `[String: RpcTransactionResponse]` dict keyed by signature.
  Alternatively, this convenience can live as a static/free function or as an extension, since `TransactionSyncer` (milestone 3.4) is the primary consumer. Placing it on `RpcApiProvider` keeps RPC concerns centralized. Add a corresponding protocol method to `IRpcApiProvider`.

### Phase 4: Wire into Protocol

- [x] **Task 14: Update IRpcApiProvider protocol with typed convenience methods**
  Files: `Sources/SolanaKit/Core/Protocols.swift`, `Sources/SolanaKit/Api/RpcApiProvider.swift`
  Add protocol extension methods on `IRpcApiProvider` that wrap `fetch(rpc:)` with typed `JsonRpc` subclasses, providing a clean call-site API for managers:
  ```swift
  extension IRpcApiProvider {
      func getBalance(address: String) async throws -> Int64
      func getBlockHeight() async throws -> Int64
      func getTokenAccountsByOwner(address: String) async throws -> [RpcKeyedAccount]
      func getSignaturesForAddress(address: String, limit: Int?, before: String?, until: String?) async throws -> [SignatureInfo]
      func getTransaction(signature: String) async throws -> RpcTransactionResponse?
      func sendTransaction(serializedBase64: String) async throws -> String
      func getLatestBlockhash() async throws -> RpcBlockhashResponse
      func getMultipleAccounts(addresses: [String]) async throws -> [BufferInfo?]
  }
  ```
  These are protocol extensions (default implementations) so they don't need to be overridden — they simply create the appropriate `JsonRpc` subclass and call `fetch(rpc:)`. This keeps the protocol requirement minimal (`fetch` + `fetchBatch`) while providing a typed API surface.

## Commit Plan
- **Commit 1** (after tasks 1-3): "Add RPC response models for transactions, signatures, and blockhash"
- **Commit 2** (after tasks 4-8): "Add typed JsonRpc subclasses for core Solana RPC endpoints"
- **Commit 3** (after tasks 9-11): "Add send, blockhash, and multi-account JsonRpc subclasses"
- **Commit 4** (after tasks 12-14): "Add batch request support and typed protocol convenience methods"
