# Review: 2.1 RPC Client — Base (Review 1)

## Scope

Files reviewed:
- `Sources/SolanaKit/Api/JsonRpc/JsonRpcResponse.swift` (new, 97 lines)
- `Sources/SolanaKit/Api/JsonRpc/JsonRpc.swift` (new, 58 lines)
- `Sources/SolanaKit/Api/RpcApiProvider.swift` (new, 83 lines)
- `Sources/SolanaKit/Core/Protocols.swift` (modified, +7 lines)
- `Sources/SolanaKit/Models/BufferInfo.swift` (new, 97 lines)

Reference files compared:
- `EvmKit.Swift/Sources/EvmKit/Api/JsonRpc/JsonRpc.swift`
- `EvmKit.Swift/Sources/EvmKit/Api/JsonRpc/JsonRpcResponse.swift`
- `EvmKit.Swift/Sources/EvmKit/Api/Core/NodeApiProvider.swift`
- `EvmKit.Swift/Sources/EvmKit/Core/Extensions.swift` (isOptional helper)
- `solana-kit-android/.../BufferInfoJsonAdapter.kt`

Build: **iOS Simulator — BUILD SUCCEEDED** (xcodebuild, zero warnings in new code)

---

## Findings

### 1. `ErrorResponse` skips `"jsonrpc"` validation — MINOR inconsistency

**File:** `JsonRpcResponse.swift:59-71`

`SuccessResponse.init?(jsonObject:)` validates `dict["jsonrpc"] != nil` (line 37), but `ErrorResponse.init?(jsonObject:)` does not. EvmKit's ObjectMapper version requires the `jsonrpc` field in both `SuccessResponse` and `ErrorResponse`.

**Impact:** A malformed dict with `{"id": 1, "error": {...}}` but no `"jsonrpc"` key would be accepted as a valid error response. In practice this is unlikely to cause runtime issues — real Solana RPC endpoints always include `"jsonrpc"`. No fix required, but worth noting for consistency.

**Suggested fix (optional):**
```swift
// ErrorResponse init, add jsonrpc check:
guard
    let dict = jsonObject as? [String: Any],
    dict["jsonrpc"] != nil,  // ← add this
    let id = dict["id"] as? Int,
```

### 2. `currentRpcId` data race under concurrent access — MINOR

**File:** `RpcApiProvider.swift:10,52`

`currentRpcId` is a mutable `var` on a non-isolated class. If `fetch(rpc:)` is called concurrently from multiple Swift Tasks, the increment on line 52 is a data race. In Swift 6 strict concurrency mode this would be flagged.

**Impact:** Low. The RPC ID is only used for request-response correlation — duplicate IDs won't cause incorrect behavior. EvmKit has the identical pattern (`NodeApiProvider.swift:11,77`), so this is a known codebase convention.

**No fix required** — matches EvmKit. Can be revisited if/when adopting Swift 6 strict concurrency (e.g., make the class an actor or use `OSAllocatedUnfairLock`).

### 3. Rate-limit error code `-32005` — MINOR verification note

**File:** `RpcApiProvider.swift:61`

The retry interceptor checks for JSON-RPC error code `-32005` (rate limiting). This is an Ethereum convention carried from EvmKit. Solana's public RPC (`api.mainnet-beta.solana.com`) does use `-32005` for rate limits, and private providers (Alchemy, QuickNode, Helius) use HTTP 429 or provider-specific errors which Alamofire handles separately.

**Impact:** None — `-32005` is correct. The retry logic is appropriate as-is.

---

## Correctness Checks

### JsonRpcResponse.swift — PASS

- `SuccessResponse`: correctly handles NSNull via `rawResult is NSNull` check (line 47). `dict.keys.contains("result")` ensures the key is present even when the value is JSON `null` (deserialized as `NSNull`, not Swift `nil`).
- `ErrorResponse`: correctly delegates to `RpcError(dict:)`.
- `RpcError`: `code`, `message` required; `data` optional. Matches JSON-RPC 2.0 spec.
- `response(jsonObject:)`: tries success first, then error, returns nil for unrecognizable payloads. Same priority as EvmKit.
- `ResponseError` enum: correctly models both error paths.

### JsonRpc.swift — PASS

- Line-for-line port of EvmKit's `JsonRpc<T>`, minus `import ObjectMapper`. Only change: `import Foundation` instead.
- `parameters(id:)`: builds correct JSON-RPC 2.0 envelope.
- `parse(response:)`: optional handling via `isOptional(T.self)` + `Any?.none as! T` matches EvmKit exactly.
- `isOptional` helper + `OptionalProtocol` + `Optional` extension: correct pattern. `private` on `OptionalProtocol` is fine since all usage is file-scoped.
- `parse(result:)` base method uses `fatalError` — subclasses must override. Same as EvmKit.

### RpcApiProvider.swift — PASS

- `init`: single URL (per plan), optional Basic Auth header via `.authorization(username: "", password: auth)` — same pattern as EvmKit.
- `fetchJson` call: parameters match `NetworkManager.fetchJson(url:method:parameters:encoding:headers:interceptor:responseCacherBehavior:)` signature exactly. `url` is `URL` which conforms to Alamofire's `URLConvertible`.
- `RequestInterceptor` conformance: only implements `retry(_:for:dueTo:completion:)`. `adapt(_:for:completion:)` has a default no-op implementation in Alamofire, so this compiles and works correctly.
- Retry logic: extracts `backoff_seconds` from error data dict, defaults to 1.0s. Matches EvmKit.
- `RequestError.invalidResponse`: stores the raw json object for debugging.

### IRpcApiProvider protocol — PASS

- Clean protocol with `source` property and generic `fetch` method.
- `RpcApiProvider` conforms correctly.

### BufferInfo.swift — PASS

- Custom `Decodable` init handles the `["<base64>", "base64"]` array format correctly via `nestedUnkeyedContainer`.
- Base64 decoding: validates encoding name, validates base64 string, throws `DecodingError.dataCorrupted` with descriptive messages.
- `lamports`: `UInt64` — correct for Solana (max ~1.8 * 10^19).
- `owner`: `String` — correct (base58-encoded program address).
- `rentEpoch`: `UInt64` with string fallback — handles Solana's `u64::MAX` (18446744073709551615) which exceeds JSON number precision. Good defensive coding.
- `space`: optional `Int` — correct (not always present in older RPC versions).
- Matches Android's `BufferInfoJsonAdapter` semantics while using idiomatic Swift Codable.

---

## Architecture & Design

- **Pattern match with EvmKit**: Excellent. `JsonRpc<T>`, `JsonRpcResponse`, and `RpcApiProvider` are near-identical ports with ObjectMapper replaced by dict-based parsing. Future developers familiar with EvmKit will immediately recognize the structure.
- **Single URL simplification**: Appropriate for Solana's RPC model. EvmKit's multi-URL fallback with `urlIndex` cycling is unnecessary here.
- **BufferInfo as Decodable**: Clean approach. When used via `JsonRpc<T>.parse(result:)`, the caller will need to re-serialize the `Any` dict to `Data` then decode — this is the standard pattern when bridging `Any`-based JSON with `Codable` and will be implemented in milestone 2.2's typed RPC methods.
- **No unused code**: Every type is either used internally or designed for use in the next milestone.

---

## Summary

| Category | Status |
|----------|--------|
| Compilation | PASS (zero errors, zero warnings) |
| Correctness | PASS |
| EvmKit pattern match | PASS |
| Android parity | PASS |
| Security | PASS (no injection vectors, auth handled correctly) |
| Thread safety | MINOR note (currentRpcId, matches EvmKit) |

All 4 plan tasks implemented correctly. No critical or blocking issues found.

REVIEW_PASS
