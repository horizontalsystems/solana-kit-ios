## Code Review Summary

**Files Reviewed:** 5
**Risk Level:** 🟢 Low

### Scope

Files introduced by milestone 2.1 (RPC Client — Base), reviewed in their current state:

| File | Lines | Status |
|------|-------|--------|
| `Sources/SolanaKit/Api/JsonRpc/JsonRpcResponse.swift` | 97 | New |
| `Sources/SolanaKit/Api/JsonRpc/JsonRpc.swift` | 58 | New |
| `Sources/SolanaKit/Api/RpcApiProvider.swift` | 168 (83 from 2.1, rest from 2.2+) | New |
| `Sources/SolanaKit/Core/Protocols.swift` | +7 lines (IRpcApiProvider) | Modified |
| `Sources/SolanaKit/Models/BufferInfo.swift` | 97 | New |

Reference files compared:
- `EvmKit.Swift/.../Api/JsonRpc/JsonRpc.swift`
- `EvmKit.Swift/.../Api/JsonRpc/JsonRpcResponse.swift`
- `EvmKit.Swift/.../Api/Core/NodeApiProvider.swift`
- `EvmKit.Swift/.../Core/Extensions.swift` (isOptional helper)

Build: **iOS Simulator (iPhone 16e, iOS 26.1) — BUILD SUCCEEDED** (zero errors; Sendable warnings in RpcApiProvider are Swift 6 prep, not blocking)

---

### Context Gates

- **ARCHITECTURE.md:** PASS — `RpcApiProvider` lives in `Api/` (infrastructure layer), accessed through `IRpcApiProvider` protocol in `Core/Protocols.swift`. No upward coupling. Layer rules respected.
- **RULES.md:** N/A (file does not exist) — WARN (non-blocking)
- **ROADMAP.md:** PASS — Milestone 2.1 marked `[x]` complete. All 4 plan tasks (JsonRpcResponse, JsonRpc<T>, RpcApiProvider, BufferInfo) implemented.

---

### Critical Issues

None.

---

### Suggestions

None.

---

### Positive Notes

1. **Faithful EvmKit port.** `JsonRpc<T>`, `JsonRpcResponse`, and `RpcApiProvider` are near-identical to EvmKit's `JsonRpc<T>`, `JsonRpcResponse`, and `NodeApiProvider`, with ObjectMapper replaced by clean dict-based parsing. Developers familiar with EvmKit will immediately recognize the structure.

2. **JsonRpcResponse dict parsing is robust.** `SuccessResponse` validates `jsonrpc` key, checks `dict.keys.contains("result")` for key presence, and handles `NSNull` correctly (line 47-51). The `response(jsonObject:)` factory tries success first, then error, matching EvmKit's priority.

3. **JsonRpc<T> optional handling.** The `isOptional` / `OptionalProtocol` / `Optional` extension pattern (lines 44-58) correctly handles `JsonRpc<T?>` subclasses where a null result is valid. The `private` on `OptionalProtocol` (vs EvmKit's module-internal) is appropriate since all usage is file-scoped.

4. **BufferInfo Codable adapter.** Handles Solana's `["base64-string", "base64"]` array format with `nestedUnkeyedContainer`. The `rentEpoch` UInt64-with-string-fallback (lines 76-89) is good defensive coding — Solana's `u64::MAX` (18446744073709551615) exceeds JSON number precision in some implementations. Error messages in `DecodingError.dataCorrupted` are descriptive and include context.

5. **RpcApiProvider** is a clean single-URL simplification of EvmKit's multi-URL `NodeApiProvider`. Auth header via `.authorization(username: "", password: auth)` matches EvmKit. The Alamofire `RequestInterceptor` retry logic for `-32005` rate-limit errors is consistent with EvmKit's implementation.

6. **No unused code.** Every type is either used internally or designed for consumption by milestone 2.2's typed RPC endpoints.

REVIEW_PASS
