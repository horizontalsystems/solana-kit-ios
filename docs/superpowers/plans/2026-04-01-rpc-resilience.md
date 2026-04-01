# RPC Resilience: Key Rotation + Throttle + Balance-Triggered ATA Sync

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate 429 rate limit errors by adding EvmKit-style key rotation with round-robin failover, global 300ms throttle between RPC requests, and balance-change-triggered ATA signature fetching (0 extra RPC calls in steady-state).

**Architecture:** Three layers of protection — (1) multiple RPC URLs with automatic failover at `RpcApiProvider` level, (2) per-request throttle via actor that computes delay without suspending inside critical section, (3) smart ATA sync that only queries ATAs whose balance actually changed, with cache updated only after successful commit.

**Tech Stack:** Swift, SolanaKit (Alamofire, GRDB, async/await)

---

## Changes Overview

```
Sources/SolanaKit/
├── Models/
│   └── RpcSource.swift                     ← MODIFY: url → urls
├── Api/
│   └── RpcApiProvider.swift                ← MODIFY: round-robin + throttle
├── Transactions/
│   └── SignatureProviders/
│       └── TokenAccountSignatureProvider.swift  ← MODIFY: balance-triggered
├── Core/
│   └── Kit.swift                           ← MODIFY: pass urls array

unstoppable-wallet-ios/UnstoppableWallet/
├── Core/Providers/
│   └── AppConfig.swift                     ← MODIFY: comma-separated keys
├── Core/Managers/
│   └── SolanaRpcSourceManager.swift        ← MODIFY: multi-key RpcSource
│   └── SolanaKitManager.swift              ← no change (already passes rpcSource)
```

---

### Task 1: RpcSource — Support Multiple URLs

**Files:**
- Modify: `Sources/SolanaKit/Models/RpcSource.swift`
- Modify: `Sources/SolanaKit/Core/Kit.swift`

- [ ] **Step 1: Change `url: URL` to `urls: [URL]`**

Replace the entire `RpcSource` struct and its extension with:

```swift
public struct RpcSource {
    public enum Network: String {
        case mainnetBeta = "mainnet-beta"
        case testnet
        case devnet
    }

    public let name: String
    public let urls: [URL]
    public let network: Network
    public let syncInterval: TimeInterval

    public var isMainnet: Bool {
        network == .mainnetBeta
    }

    /// First URL — for backward compatibility and display.
    public var url: URL {
        urls[0]
    }

    public init(name: String, urls: [URL], network: Network, syncInterval: TimeInterval = 30) {
        precondition(!urls.isEmpty, "RpcSource requires at least one URL")
        self.name = name
        self.urls = urls
        self.network = network
        self.syncInterval = syncInterval
    }

    /// Convenience init for single URL (backward compatibility).
    public init(name: String, url: URL, network: Network, syncInterval: TimeInterval = 30) {
        self.init(name: name, urls: [url], network: network, syncInterval: syncInterval)
    }
}

public extension RpcSource {
    /// Alchemy mainnet-beta with multiple API keys (round-robin).
    static func alchemy(apiKeys: [String]) -> RpcSource {
        let urls = apiKeys.compactMap { URL(string: "https://solana-mainnet.g.alchemy.com/v2/\($0)") }
        return RpcSource(name: "Alchemy", urls: urls, network: .mainnetBeta, syncInterval: 30)
    }

    /// Alchemy mainnet-beta with single API key.
    static func alchemy(apiKey: String) -> RpcSource {
        alchemy(apiKeys: [apiKey])
    }

    static func quickNode(url: URL) -> RpcSource {
        RpcSource(name: "QuickNode", url: url, network: .mainnetBeta, syncInterval: 30)
    }

    static func mainnetBeta() -> RpcSource {
        RpcSource(
            name: "Solana Mainnet",
            url: URL(string: "https://api.mainnet-beta.solana.com")!,
            network: .mainnetBeta,
            syncInterval: 30
        )
    }

    static func devnet() -> RpcSource {
        RpcSource(
            name: "Solana Devnet",
            url: URL(string: "https://api.devnet.solana.com")!,
            network: .devnet,
            syncInterval: 30
        )
    }
}
```

- [ ] **Step 2: Update Kit.swift** — change `RpcApiProvider` init from `url: rpcSource.url` to `urls: rpcSource.urls`.

- [ ] **Step 3: Commit**

```bash
git add Sources/SolanaKit/Models/RpcSource.swift Sources/SolanaKit/Core/Kit.swift
git commit -m "feat: RpcSource supports multiple URLs for key rotation"
```

---

### Task 2: RpcApiProvider — Round-Robin Failover + Throttle

**Files:**
- Modify: `Sources/SolanaKit/Api/RpcApiProvider.swift`

- [ ] **Step 1: Replace RpcApiProvider with round-robin + throttle implementation**

Key design decisions:
- `RpcState` actor owns URL rotation, RPC ID counter, and throttle delay computation
- `acquireSlot()` is synchronous inside the actor (no `Task.sleep` inside actor — avoids race condition)
- Caller sleeps OUTSIDE the actor with the returned delay
- Retry goes through throttle (shared key protection > fast failover)
- `fetchBatch` also uses throttle + URL rotation (no retry — batch failure retries on next heartbeat)

```swift
import Alamofire
import Foundation
import HsToolKit

class RpcApiProvider {
    private let networkManager: NetworkManager
    private let urls: [URL]
    private let headers: HTTPHeaders
    private let logger: Logger?

    private let state = RpcState()

    init(networkManager: NetworkManager, urls: [URL], auth: String?, logger: Logger? = nil) {
        self.networkManager = networkManager
        self.urls = urls
        self.logger = logger

        var headers = HTTPHeaders()
        if let auth {
            headers.add(.authorization(username: "", password: auth))
        }
        self.headers = headers
    }

    /// Thread-safe state: round-robin URL selection, RPC ID counter, throttle delay.
    /// All mutations are synchronous inside the actor — no suspension in critical section.
    private actor RpcState {
        private let minInterval: TimeInterval = 0.3
        private var nextRequestTime: TimeInterval = 0
        private var urlIndex = 0
        private var rpcId = 0

        /// Returns the next URL, a unique RPC ID, and the delay to wait before sending.
        /// Does NOT suspend — computes the slot and advances state atomically.
        func acquireSlot(urls: [URL]) -> (url: URL, rpcId: Int, delay: TimeInterval) {
            let now = Date().timeIntervalSince1970
            let delay = max(0, nextRequestTime - now)
            nextRequestTime = now + delay + minInterval

            let url = urls[urlIndex]
            urlIndex = (urlIndex + 1) % urls.count

            rpcId += 1
            return (url, rpcId, delay)
        }
    }

    /// Waits for the throttle delay, then returns the URL and RPC ID.
    private func nextSlot() async -> (url: URL, rpcId: Int) {
        let (url, rpcId, delay) = await state.acquireSlot(urls: urls)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return (url, rpcId)
    }

    private func rpcResult<T>(rpc: JsonRpc<T>, attempt: Int = 0) async throws -> T {
        let (url, rpcId) = await nextSlot()

        do {
            let json = try await networkManager.fetchJson(
                url: url,
                method: .post,
                parameters: rpc.parameters(id: rpcId),
                encoding: JSONEncoding.default,
                headers: headers,
                interceptor: self,
                responseCacherBehavior: .doNotCache
            )

            guard let rpcResponse = JsonRpcResponse.response(jsonObject: json) else {
                throw RequestError.invalidResponse(jsonObject: json)
            }

            return try rpc.parse(response: rpcResponse)
        } catch {
            if attempt < urls.count * 2 {
                logger?.debug("RpcApiProvider: request failed (attempt \(attempt + 1), url: \(url.host ?? "?")), retrying: \(error)")
                return try await rpcResult(rpc: rpc, attempt: attempt + 1)
            }
            throw error
        }
    }
}

// MARK: - IRpcApiProvider

extension RpcApiProvider: IRpcApiProvider {
    var source: String {
        urls.first?.host ?? "unknown"
    }

    func fetch<T>(rpc: JsonRpc<T>) async throws -> T {
        try await rpcResult(rpc: rpc)
    }

    func fetchBatch<T>(rpcs: [JsonRpc<T>]) async throws -> [T?] {
        guard !rpcs.isEmpty else { return [] }

        let (url, _) = await nextSlot()

        let requestArray = rpcs.enumerated().map { $0.element.parameters(id: $0.offset) }
        let bodyData = try JSONSerialization.data(withJSONObject: requestArray, options: [])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }

        let (data, _) = try await URLSession.shared.data(for: request)

        guard
            let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
            let responseArray = jsonObject as? [[String: Any]]
        else {
            throw RequestError.invalidResponse(jsonObject: data)
        }

        var results: [T?] = Array(repeating: nil, count: rpcs.count)
        for dict in responseArray {
            guard
                let id = dict["id"] as? Int,
                id >= 0, id < rpcs.count,
                let rpcResponse = JsonRpcResponse.response(jsonObject: dict)
            else {
                logger?.warning("RpcApiProvider: batch — invalid id or structure: \(dict["id"] ?? "nil")")
                continue
            }

            do {
                results[id] = try rpcs[id].parse(response: rpcResponse)
            } catch {
                logger?.error("RpcApiProvider: batch parse failed for id \(id): \(error)")
            }
        }
        return results
    }
}

// MARK: - Batch Transaction Convenience

extension RpcApiProvider {
    func fetchTransactionsBatch(signatures: [String]) async throws -> [String: RpcTransactionResponse] {
        let batchChunkSize = 100
        var result: [String: RpcTransactionResponse] = [:]

        let chunks = signatures.chunked(into: batchChunkSize)
        for (chunkIndex, chunk) in chunks.enumerated() {
            let rpcs = chunk.map { GetTransactionJsonRpc(signature: $0) }
            let responses: [RpcTransactionResponse??] = try await fetchBatch(rpcs: rpcs)
            var chunkParsed = 0
            for (signature, maybeResponse) in zip(chunk, responses) {
                if let outerOpt = maybeResponse, let tx = outerOpt {
                    result[signature] = tx
                    chunkParsed += 1
                }
            }
            logger?.debug("RpcApiProvider: batch chunk \(chunkIndex + 1)/\(chunks.count) — \(chunkParsed)/\(chunk.count) parsed")
        }

        return result
    }
}

// MARK: - Array chunk helper

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - RequestInterceptor (Alamofire retry for RPC -32005)

extension RpcApiProvider: RequestInterceptor {
    func retry(_: Request, for _: Session, dueTo error: Error, completion: @escaping (RetryResult) -> Void) {
        if case let JsonRpcResponse.ResponseError.rpcError(rpcError) = error, rpcError.code == -32005 {
            var backoffSeconds = 1.0
            if let errorData = rpcError.data as? [String: Any],
               let timeInterval = errorData["backoff_seconds"] as? TimeInterval
            {
                backoffSeconds = timeInterval
            }
            completion(.retryWithDelay(backoffSeconds))
        } else {
            completion(.doNotRetry)
        }
    }
}

// MARK: - Errors

extension RpcApiProvider {
    enum RequestError: Error {
        case invalidResponse(jsonObject: Any)
    }
}
```

- [ ] **Step 2: Update Kit.swift** — `urls: rpcSource.urls` (if not already done in Task 1)

- [ ] **Step 3: Commit**

```bash
git add Sources/SolanaKit/Api/RpcApiProvider.swift Sources/SolanaKit/Core/Kit.swift
git commit -m "feat: round-robin URL failover + 300ms throttle in RpcApiProvider"
```

---

### Task 3: Balance-Triggered ATA Sync

**Files:**
- Modify: `Sources/SolanaKit/Transactions/SignatureProviders/TokenAccountSignatureProvider.swift`

- [ ] **Step 1: Add cached balances with deferred update**

Key design decisions:
- `cachedBalances` stores last-known balances per ATA address
- Balance change detection happens BEFORE fetching signatures
- `cachedBalances` is updated ONLY inside `commitCursors()` — NOT during fetch
- If sync fails (no commit), cache stays stale → next cycle re-detects same changes → no data loss
- `pendingBalances` holds the snapshot to commit

Add properties:

```swift
/// Last-known balances per ATA address — updated only on commitCursors().
private var cachedBalances: [String: String] = [:]

/// Balances snapshot from the latest fetch — staged for commit.
private var pendingBalances: [String: String] = [:]
```

- [ ] **Step 2: Replace beginning of `fetchNewSignatures()`**

```swift
func fetchNewSignatures() async throws -> [SignatureInfo] {
    let allAccounts = storage.fungibleTokenAccounts()
    guard !allAccounts.isEmpty else {
        logger?.debug("TokenAccountSignatureProvider: no fungible token accounts, skipping")
        return []
    }

    // Detect which ATAs have changed balance since last committed sync.
    let currentBalances = Dictionary(uniqueKeysWithValues: allAccounts.map { ($0.address, $0.balance) })
    let changedAccounts: [TokenAccount]

    if cachedBalances.isEmpty {
        // First run after Kit creation — sync all ATAs to establish cursors.
        changedAccounts = allAccounts
        logger?.debug("TokenAccountSignatureProvider: first run, syncing all \(allAccounts.count) ATA(s)")
    } else {
        changedAccounts = allAccounts.filter { account in
            cachedBalances[account.address] != account.balance
        }
        if changedAccounts.isEmpty {
            logger?.debug("TokenAccountSignatureProvider: no balance changes in \(allAccounts.count) ATA(s), skipping")
            return []
        }
        logger?.debug("TokenAccountSignatureProvider: \(changedAccounts.count)/\(allAccounts.count) ATA(s) have balance changes")
    }

    // Stage balances for commit — do NOT update cachedBalances here.
    pendingBalances = currentBalances

    var allSignatures: [SignatureInfo] = []
    var ataSuccessCount = 0
    var ataFailCount = 0
    pendingCursors = [:]

    for account in changedAccounts {
        // ... existing per-ATA fetch loop (unchanged)
    }

    logger?.debug("TokenAccountSignatureProvider: done — \(allSignatures.count) signature(s), \(ataSuccessCount) ATA(s) ok, \(ataFailCount) failed")
    return allSignatures
}
```

- [ ] **Step 3: Update `commitCursors()` to also commit cached balances**

```swift
func commitCursors() throws {
    // Commit ATA signature cursors.
    if !pendingCursors.isEmpty {
        for (cursorName, signature) in pendingCursors {
            try storage.save(lastSyncedTransaction: LastSyncedTransaction(
                syncSourceName: cursorName,
                hash: signature
            ))
        }
        logger?.debug("TokenAccountSignatureProvider: committed \(pendingCursors.count) cursor(s)")
        pendingCursors = [:]
    }

    // Commit balance cache — only after successful persist.
    if !pendingBalances.isEmpty {
        cachedBalances = pendingBalances
        pendingBalances = [:]
        logger?.debug("TokenAccountSignatureProvider: committed balance cache (\(cachedBalances.count) ATA(s))")
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/SolanaKit/Transactions/SignatureProviders/TokenAccountSignatureProvider.swift
git commit -m "feat: balance-triggered ATA sync — 0 extra RPC calls in steady-state"
```

---

### Task 4: Wallet App — Multiple Alchemy Keys

**Files:**
- Modify: `unstoppable-wallet-ios/UnstoppableWallet/UnstoppableWallet/Core/Providers/AppConfig.swift`
- Modify: `unstoppable-wallet-ios/UnstoppableWallet/UnstoppableWallet/Core/Managers/SolanaRpcSourceManager.swift`

- [ ] **Step 1: AppConfig — comma-separated keys**

Add new property (keep existing `solanaAlchemyApiKey` for backward compat):

```swift
static var solanaAlchemyApiKeys: [String] {
    ((Bundle.main.object(forInfoDictionaryKey: "SolanaAlchemyApiKey") as? String) ?? "")
        .components(separatedBy: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}
```

- [ ] **Step 2: SolanaRpcSourceManager — use multiple keys**

Replace `allRpcSources`:

```swift
var allRpcSources: [SolanaKit.RpcSource] {
    var sources = [SolanaKit.RpcSource]()
    let apiKeys = AppConfig.solanaAlchemyApiKeys
    if !apiKeys.isEmpty {
        sources.append(.alchemy(apiKeys: apiKeys))
    }
    sources.append(.mainnetBeta())
    return sources
}
```

- [ ] **Step 3: Add comma-separated keys to build config**

In the xcconfig where `SolanaAlchemyApiKey` is defined:
```
SolanaAlchemyApiKey = key1,key2,key3
```

- [ ] **Step 4: Commit**

```bash
git add UnstoppableWallet/UnstoppableWallet/Core/Providers/AppConfig.swift
git add UnstoppableWallet/UnstoppableWallet/Core/Managers/SolanaRpcSourceManager.swift
git commit -m "feat: support multiple Solana Alchemy API keys with rotation"
```

---

## Verification

1. **Build both projects** — solana-kit-ios and unstoppable-wallet-ios
2. **Test key rotation** — add 2+ Alchemy keys, verify logs show alternating URLs
3. **Test throttle** — verify no 429 errors, minimum 300ms between requests in logs
4. **Test failover** — add one invalid key + one valid key, verify automatic recovery with retry logs
5. **Test balance-triggered ATA** — with no balance changes, verify "no balance changes, skipping" in logs
6. **Test incoming transfer** — execute swap, verify balance change detected → signatures fetched → transaction appears
7. **Test failure recovery** — kill network during ATA sync, verify cachedBalances NOT updated (commit didn't happen) → next cycle re-detects changes

## Result: RPC Call Budget Per Sync Cycle

| Component | Before | After |
|-----------|--------|-------|
| `getBlockHeight` | 1 | 1 |
| `getBalance` (SOL) | 1 | 1 |
| `getTokenAccountsByOwner` | 1 | 1 |
| `getSignaturesForAddress` (wallet) | 1 | 1 |
| `getSignaturesForAddress` (per ATA) | N (always) | 0 (steady) / 1-2 (on change) |
| **Total (4 tokens, steady)** | **8** | **4** |
| **Total (4 tokens, 1 transfer)** | **8** | **5** |
