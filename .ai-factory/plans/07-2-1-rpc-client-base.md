# Plan: 2.1 RPC Client — Base

## Context

Build the generic JSON-RPC 2.0 client infrastructure for Solana: request/response envelope types, the HTTP client wrapping HsToolKit's `NetworkManager` (Alamofire), error handling, and a custom `BufferInfo` Codable adapter for Solana's base64-encoded account data. This provides the networking foundation that milestone 2.2 (typed RPC endpoints) will build on.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Design Decisions

**Request serialization — `[String: Any]` + `JSONEncoding` (same as EvmKit):**
EvmKit's `JsonRpc<T>.parameters(id:)` returns `[String: Any]` passed to `NetworkManager.fetchJson` with `JSONEncoding.default`. This works for Solana's heterogeneous params arrays (e.g. `["<pubkey>", {"commitment":"confirmed"}]`). Follow this pattern exactly.

**Response parsing — dict-based, no ObjectMapper:**
EvmKit uses ObjectMapper `ImmutableMappable` for `JsonRpcResponse`. Since solana-kit-ios has no ObjectMapper dependency and the JSON-RPC envelope is trivial (`id`, `result`, `error`), parse the response `Any` (from `fetchJson`) with simple `[String: Any]` dict casting. Each `JsonRpc<T>` subclass's `parse(result:)` handles method-specific parsing (Codable, dict casting, or simple type coercion).

**Single URL (no multi-URL fallback):**
EvmKit's `NodeApiProvider` supports multiple fallback URLs. Solana RPC providers (Alchemy, QuickNode) use a single endpoint. Start with one URL; expand if needed later.

## Tasks

### Phase 1: JSON-RPC Foundation

- [x] **Task 1: JSON-RPC response envelope types**
  Files: `Sources/SolanaKit/Api/JsonRpc/JsonRpcResponse.swift`

  Create `JsonRpcResponse` enum mirroring EvmKit's `Api/JsonRpc/JsonRpcResponse.swift` but with dict-based parsing instead of ObjectMapper:

  - `enum JsonRpcResponse` with cases `.success(SuccessResponse)` and `.error(ErrorResponse)`
  - `SuccessResponse` struct: `id: Int`, `result: Any?`. Init from `[String: Any]` dict — require `"jsonrpc"` and `"id"` keys, require `"result"` key to be present (value may be nil/NSNull)
  - `ErrorResponse` struct: `id: Int`, `error: RpcError`. Init from dict — require `"error"` key
  - `RpcError` struct: `code: Int`, `message: String`, `data: Any?`. Init from dict
  - `static func response(jsonObject: Any) -> JsonRpcResponse?` — tries SuccessResponse first, then ErrorResponse, returns nil if neither (same logic as EvmKit)
  - `enum ResponseError: Error` with cases `.rpcError(RpcError)` and `.invalidResult(value: Any?)` (same as EvmKit)

  Reference: `/Users/max/projects/unstoppable/EvmKit.Swift/Sources/EvmKit/Api/JsonRpc/JsonRpcResponse.swift` — mirror the public API shape exactly, replace `ImmutableMappable` with dict-based `init?(jsonObject: Any)` initializers.

- [x] **Task 2: JsonRpc\<T\> base class** (depends on Task 1)
  Files: `Sources/SolanaKit/Api/JsonRpc/JsonRpc.swift`

  Create `JsonRpc<T>` open class mirroring EvmKit's `Api/JsonRpc/JsonRpc.swift`:

  ```swift
  open class JsonRpc<T> {
      let method: String
      let params: [Any]

      public init(method: String, params: [Any] = [])

      // Builds the JSON-RPC 2.0 request envelope dict
      func parameters(id: Int = 1) -> [String: Any]
      // Returns: ["jsonrpc": "2.0", "method": method, "params": params, "id": id]

      // Subclasses override to parse the "result" value into T
      open func parse(result: Any) throws -> T {
          fatalError("Must override")
      }

      // Dispatches a JsonRpcResponse to parse(result:) or throws on error
      func parse(response: JsonRpcResponse) throws -> T
      // On .success: guard result != nil (unless T is Optional via isOptional check), call parse(result:)
      // On .error: throw ResponseError.rpcError(error)
  }
  ```

  Include the `isOptional(_:)` helper (same as EvmKit uses) to handle optional result types gracefully. No external dependencies — only imports `Foundation` and the `JsonRpcResponse` from Task 1.

  Reference: `/Users/max/projects/unstoppable/EvmKit.Swift/Sources/EvmKit/Api/JsonRpc/JsonRpc.swift` — port line-for-line, removing the `import ObjectMapper`.

### Phase 2: HTTP Client

- [x] **Task 3: RpcApiProvider + IRpcApiProvider protocol** (depends on Tasks 1–2)
  Files: `Sources/SolanaKit/Api/RpcApiProvider.swift`, `Sources/SolanaKit/Core/Protocols.swift`

  **In `Protocols.swift`** — add `IRpcApiProvider` protocol (append below existing storage protocols):

  ```swift
  protocol IRpcApiProvider {
      var source: String { get }
      func fetch<T>(rpc: JsonRpc<T>) async throws -> T
  }
  ```

  **In `Api/RpcApiProvider.swift`** — create `RpcApiProvider` class mirroring EvmKit's `NodeApiProvider`:

  - Init: `init(networkManager: NetworkManager, url: URL, auth: String?)` — single URL (not array), optional Basic Auth header (for Alchemy API key passed as header)
  - Private `var currentRpcId: Int = 0` — monotonically incrementing per-request
  - Core method `private func rpcResult<T>(rpc: JsonRpc<T>, parameters: [String: Any]) async throws -> T`:
    1. Call `networkManager.fetchJson(url: url, method: .post, parameters: parameters, encoding: JSONEncoding.default, headers: headers, interceptor: self, responseCacherBehavior: .doNotCache)`
    2. Guard-let `JsonRpcResponse.response(jsonObject: json)` else throw `RequestError.invalidResponse`
    3. Return `try rpc.parse(response: rpcResponse)`
  - Conform to `IRpcApiProvider`: `fetch<T>(rpc:)` increments `currentRpcId`, calls `rpcResult`
  - Conform to Alamofire `RequestInterceptor`: on `retry`, check for `ResponseError.rpcError` with code `-32005` (rate limit) → `.retryWithDelay(backoffSeconds)`, otherwise `.doNotRetry`. Extract `backoff_seconds` from error data dict if present (same as EvmKit)
  - `enum RequestError: Error` with case `.invalidResponse(jsonObject: Any)`
  - `var source: String` returns `url.host ?? url.absoluteString`

  Imports: `Foundation`, `Alamofire`, `HsToolKit`.

  Reference: `/Users/max/projects/unstoppable/EvmKit.Swift/Sources/EvmKit/Api/Core/NodeApiProvider.swift` — same structure, simplified to single URL.

### Phase 3: Solana-Specific Adapter

- [x] **Task 4: BufferInfo custom Codable adapter** (no dependencies on Tasks 1–3)
  Files: `Sources/SolanaKit/Models/BufferInfo.swift`

  Create `BufferInfo` struct for Solana's account data format. The Solana RPC returns account info as:
  ```json
  {
    "data": ["<base64-encoded-bytes>", "base64"],
    "lamports": 1000000,
    "owner": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA",
    "executable": false,
    "rentEpoch": 18446744073709551615,
    "space": 165
  }
  ```

  The `data` field is a 2-element JSON array `[base64String, encodingName]`. Android handles this with `BufferInfoJsonAdapter` + Moshi (see `/Users/max/projects/unstoppable/solana-kit-android/solanakit/src/main/java/io/horizontalsystems/solanakit/models/BufferInfoJsonAdapter.kt`).

  Implementation:

  ```swift
  struct BufferInfo: Decodable {
      let data: Data            // decoded from base64
      let lamports: UInt64
      let owner: String         // base58 program address
      let executable: Bool
      let rentEpoch: UInt64     // UInt64 — modern Solana values exceed Int64.max
      let space: Int?

      init(from decoder: Decoder) throws {
          let container = try decoder.container(keyedBy: CodingKeys.self)

          // Decode the data field: ["<base64-string>", "base64"]
          var dataArray = try container.nestedUnkeyedContainer(forKey: .data)
          let base64String = try dataArray.decode(String.self)
          let encoding = try dataArray.decode(String.self)
          guard encoding == "base64" else {
              throw DecodingError.dataCorrupted(...)
          }
          guard let decoded = Data(base64Encoded: base64String) else {
              throw DecodingError.dataCorrupted(...)
          }
          data = decoded

          lamports = try container.decode(UInt64.self, forKey: .lamports)
          owner = try container.decode(String.self, forKey: .owner)
          executable = try container.decode(Bool.self, forKey: .executable)

          // rentEpoch: decode as UInt64 directly (Solana sends as JSON number or string)
          // Try UInt64 first, fall back to String → UInt64 conversion
          if let value = try? container.decode(UInt64.self, forKey: .rentEpoch) {
              rentEpoch = value
          } else {
              let stringValue = try container.decode(String.self, forKey: .rentEpoch)
              guard let parsed = UInt64(stringValue) else {
                  throw DecodingError.dataCorrupted(...)
              }
              rentEpoch = parsed
          }

          space = try container.decodeIfPresent(Int.self, forKey: .space)
      }

      private enum CodingKeys: String, CodingKey {
          case data, lamports, owner, executable, rentEpoch, space
      }
  }
  ```

  Key points from Android reference:
  - Android's `HSBufferInfoJson` stores `rentEpoch` as `String` because it overflows `Long`; the adapter converts via `toULong().toLong()`. In Swift, use `UInt64` natively.
  - Android uses Borsh to decode the inner data bytes into `AccountInfo` (SPL token account layout). For this base milestone, keep `data` as raw `Data` — typed inner decoders (SPL token account layout, mint layout) will be added in milestone 2.2 or 3.2 when they're needed.
  - The `owner` field is the program that owns the account (e.g. Token Program address) — store as `String` (base58).

## Commit Plan
- **Commit 1** (after tasks 1-4): "Add generic JSON-RPC 2.0 client with BufferInfo adapter"
