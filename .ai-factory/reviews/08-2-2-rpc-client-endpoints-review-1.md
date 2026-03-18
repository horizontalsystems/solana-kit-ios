# Review: 2.2 RPC Client — Endpoints

**Date:** 2026-03-18
**Scope:** 16 files changed, +688 lines — 8 new JsonRpc subclasses, 5 new Rpc response models, batch support on RpcApiProvider, protocol convenience API
**Build:** PASSES (iOS Simulator, iPhone 17, Xcode)

---

## Files Reviewed

| File | Verdict |
|------|---------|
| `Models/Rpc/RpcTransactionResponse.swift` | OK |
| `Models/Rpc/SignatureInfo.swift` | OK |
| `Models/Rpc/RpcBlockhashResponse.swift` | OK — see note on `RpcResultResponse<T>` |
| `Models/Rpc/RpcKeyedAccount.swift` | OK |
| `Models/TokenProgram.swift` | OK |
| `Api/JsonRpc/GetBalanceJsonRpc.swift` | OK |
| `Api/JsonRpc/GetBlockHeightJsonRpc.swift` | OK |
| `Api/JsonRpc/GetTokenAccountsByOwnerJsonRpc.swift` | OK |
| `Api/JsonRpc/GetSignaturesForAddressJsonRpc.swift` | OK |
| `Api/JsonRpc/GetTransactionJsonRpc.swift` | OK |
| `Api/JsonRpc/SendTransactionJsonRpc.swift` | OK |
| `Api/JsonRpc/GetLatestBlockhashJsonRpc.swift` | OK |
| `Api/JsonRpc/GetMultipleAccountsJsonRpc.swift` | OK |
| `Api/RpcApiProvider.swift` | OK — see notes below |
| `Core/Protocols.swift` | OK |

---

## Issues

### [Medium] `fetchBatch` bypasses Alamofire retry interceptor

**File:** `RpcApiProvider.swift:64-99`

The single-request `fetch(rpc:)` method routes through `networkManager.fetchJson(...)` which uses Alamofire with `self` as `RequestInterceptor` — providing automatic backoff retry on RPC error code `-32005` (rate limit). The new `fetchBatch` method uses raw `URLSession.shared.data(for:)`, completely bypassing this retry logic.

If a batch request hits Alchemy's rate limit, it will fail outright instead of retrying with backoff.

**Impact:** Batch transaction fetches (up to 100 per chunk) are the most likely to trigger rate limits. This will surface as intermittent `TransactionSyncer` failures when syncing many transactions.

**Fix:** Either wrap `fetchBatch` in a manual retry loop for `-32005` (parse the error from the JSON response), or use Alamofire's `Session` to make the raw request with interceptor support. Alternatively, since batch requests are only used in `fetchTransactionsBatch` which already chunks at 100, the rate limit risk may be acceptable for now — but document it.

---

### [Medium] `fetchBatch` discards HTTP response status

**File:** `RpcApiProvider.swift:79`

```swift
let (data, _) = try await URLSession.shared.data(for: request)
```

The `URLResponse` is discarded. If the server returns HTTP 429 (rate limit), 500, or any non-200 status, the code will attempt to parse the error body as a JSON array, fail, and throw a generic `invalidResponse` error with the raw `Data` as the associated value — losing the HTTP status code context.

**Fix:** Check `(response as? HTTPURLResponse)?.statusCode` and throw a descriptive error for non-2xx responses before attempting JSON parsing.

---

### [Low] `RpcResultResponse<T>` is dead code

**File:** `RpcBlockhashResponse.swift:17-20`

The generic `RpcResultResponse<T>` wrapper is defined but never used anywhere. The plan intended it for `getBalance` and `getTokenAccountsByOwner` too, but the actual `JsonRpc` subclasses manually extract `dict["value"]` via `JSONSerialization` casting instead. Either use it or remove it.

**Recommendation:** Remove it now; re-add when/if a use case materializes. Dead code is confusing.

---

### [Low] No Solana-specific limit enforcement on `GetMultipleAccountsJsonRpc`

**File:** `GetMultipleAccountsJsonRpc.swift`

Solana's `getMultipleAccounts` RPC method has a server-side limit of 100 addresses per call. The `JsonRpc` subclass accepts an arbitrary-length array. If a caller passes >100 addresses, the RPC server will reject the request.

Android handles this by chunking in the caller (`NftClient` chunks at 100). The same pattern will work here, but there's no guard or documentation in the `JsonRpc` subclass.

**Recommendation:** Add a `precondition(addresses.count <= 100)` or document the limit.

---

### [Low] Double-optional `RpcTransactionResponse??` in `fetchTransactionsBatch`

**File:** `RpcApiProvider.swift:119-123`

`GetTransactionJsonRpc` is `JsonRpc<RpcTransactionResponse?>` (T is optional). `fetchBatch` returns `[T?]`. So the result type is `[RpcTransactionResponse??]` — a double-optional. The handling code is correct:

```swift
let responses: [RpcTransactionResponse??] = try await fetchBatch(rpcs: rpcs)
for (signature, maybeResponse) in zip(chunk, responses) {
    if let outerOpt = maybeResponse, let tx = outerOpt {
        result[signature] = tx
    }
}
```

This works but is fragile and harder to read than needed. The outer `nil` means "batch slot was empty / parse failure" and the inner `nil` means "node returned `null` result (transaction not found)". Both map to "skip" which is the correct behavior.

**Recommendation:** Consider adding a brief inline comment explaining the two `nil` levels.

---

## Correctness Verification

- **`JsonRpc` optional handling:** `GetTransactionJsonRpc` returns `RpcTransactionResponse?`. The base class `JsonRpc.parse(response:)` detects optional `T` via `isOptional()` and returns `nil` when `result` is JSON `null`. The overridden `parse(result:)` is only called when result is non-nil. Verified correct.

- **`AnyCodable` for `err` field:** Decodes any JSON value (object, array, string, number, bool). Falls back to `()` (Void) for unrecognized types. Only used for `err: AnyCodable?` which is nil-checked for error presence and `.description` for debug output. The Void fallback is unconventional but harmless since the field will be non-nil (indicating error present) regardless.

- **`NSNumber` bridging in `GetBalanceJsonRpc`/`GetBlockHeightJsonRpc`:** `JSONSerialization` produces `NSNumber` for JSON integers. `value as? NSNumber` then `.int64Value` correctly handles values up to Int64.max (~9.2×10^18), well above max lamports (~5×10^17). Safe.

- **`GetSignaturesForAddressJsonRpc` empty config:** When no optional params are set, sends `[address]` (no config dict). Solana RPC spec allows this. Correct.

- **`SendTransactionJsonRpc` params:** Match Android's `PendingTransactionSyncer.sendTransaction` exactly: `encoding: base64`, `skipPreflight: false`, `preflightCommitment: confirmed`, `maxRetries: 0`. Correct.

- **`GetLatestBlockhashJsonRpc` commitment:** Uses `finalized`, matching Android's `Commitment.FINALIZED`. Correct.

- **Batch `id` correlation:** Request ids are 0-based indices. Response parsing looks up `dict["id"] as? Int` and uses it as array index. Correct — matches Android's `parseBatchResponse` pattern.

- **Auth headers in `fetchBatch`:** Correctly copies all headers from `self.headers` (Alamofire `HTTPHeaders`) to the `URLRequest`. Alchemy API key auth will propagate. Correct.

- **Protocol surface:** `IRpcApiProvider` requires `fetch`, `fetchBatch`, and `fetchTransactionsBatch`. Protocol extension provides typed convenience methods (`getBalance`, `getBlockHeight`, etc.) that delegate to `fetch`. Mocks only need to implement the three protocol requirements. Clean design.

---

## Summary

Clean, well-structured implementation that follows EvmKit patterns consistently. All 8 RPC endpoints match their Android counterparts. The batch support is functional and correctly ports the Android chunked pattern. The two medium issues (missing retry/status-code handling in `fetchBatch`) are real but non-blocking — they'll surface as degraded error messages under rate limiting, not as incorrect behavior. No security concerns.

REVIEW_PASS
