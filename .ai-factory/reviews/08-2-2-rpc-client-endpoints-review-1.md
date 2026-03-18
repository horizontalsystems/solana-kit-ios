## Code Review Summary

**Files Reviewed:** 15 (8 JsonRpc subclasses, 4 Rpc model files, RpcApiProvider.swift, Protocols.swift, TokenProgram.swift)
**Risk Level:** 🟢 Low

### Context Gates

- **ARCHITECTURE.md:** WARN — `RpcResultResponse<T>` and `RpcContext` are defined in `Models/Rpc/RpcBlockhashResponse.swift` but never referenced from any code path. All JsonRpc subclasses parse manually from `[String: Any]` via `JSONSerialization`, making these generic wrappers dead code. Not a violation per se, but the architecture doc says Models must be imported by other layers — these aren't.
- **RULES.md:** File not present — no gate.
- **ROADMAP.md:** Milestone 2.2 is correctly marked complete. All deliverables listed in the roadmap (typed RPC methods, batch support) are implemented.

### Critical Issues

None.

### Suggestions

1. **`fetchBatch` ignores HTTP status code** (`RpcApiProvider.swift:79`)
   The batch method discards the `URLResponse` from `URLSession.shared.data(for:)`. If the RPC node returns an HTTP error (429 rate-limit, 500 internal error, 403 auth failure), the code attempts to parse the error body as a JSON-RPC array and throws a misleading `RequestError.invalidResponse` instead of surfacing the actual HTTP status. Consider:
   ```swift
   let (data, response) = try await URLSession.shared.data(for: request)
   if let httpResponse = response as? HTTPURLResponse,
      !(200...299).contains(httpResponse.statusCode) {
       throw RequestError.invalidResponse(jsonObject: httpResponse.statusCode)
   }
   ```

2. **Dead code: `RpcResultResponse<T>` and `RpcContext`** (`Models/Rpc/RpcBlockhashResponse.swift:10-20`)
   These generic structs were created per plan Task 3 ("reused by getBalance and getTokenAccountsByOwner too") but no code path actually uses them — all JsonRpc subclasses parse from raw `[String: Any]` dicts via `JSONSerialization`. Either remove them or refactor at least one parse method to use `RpcResultResponse<T>` for consistency. As-is, they add maintenance surface for no benefit.

3. **`fetchTransactionsBatch` not available as protocol default** (`Protocols.swift:29`, `RpcApiProvider.swift:104-129`)
   `fetchTransactionsBatch` is a protocol requirement on `IRpcApiProvider` but is only implemented on the concrete `RpcApiProvider` class (not as a protocol extension). Since the method body only calls `fetchBatch(rpcs:)` — which IS on the protocol — this could be a protocol extension, giving mock/test implementations the default for free. Currently, any mock conforming to `IRpcApiProvider` must manually implement this method.

### Positive Notes

- The double-optional handling in `fetchTransactionsBatch` (`[RpcTransactionResponse??]`) is correctly annotated and unwrapped with the `if let outerOpt = maybeResponse, let tx = outerOpt` pattern — this is a tricky area and it's done right.
- Consistent parse pattern across all JsonRpc subclasses: extract from `[String: Any]`, serialize to `Data`, decode via `JSONDecoder`. Easy to follow and extend.
- The `AnyCodable` wrapper is well-designed for its purpose — handles all JSON value types and gracefully falls back to `()` for edge cases.
- Good use of `NSNumber.int64Value` for balance parsing, avoiding precision loss from intermediate `Int` conversion on 32-bit platforms.
- Batch request IDs use index-based assignment (0-based) which avoids the thread-safety concern present in the single-request `currentRpcId` counter.
- `chunked(into:)` array helper is defensive against `size <= 0`.

REVIEW_PASS
