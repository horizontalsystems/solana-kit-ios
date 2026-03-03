---
name: solana-rpc-swift
description: Use when implementing Solana JSON-RPC calls in Swift using URLSession + Codable for solana-kit-ios. Covers RPC method patterns, request/response types, a generic RpcClient, key Solana types, base58 encoding, and common pitfalls. Swift-specific — not JS/TS.
---

# Solana JSON-RPC in Swift

Swift implementation guide for Solana JSON-RPC calls using `URLSession` + `Codable`, targeting the `solana-kit-ios` Swift Package (porting `solana-kit-android`).

## Core Workflow

1. Define `RpcRequest` / `RpcResponse` Codable structs
2. Implement a generic `RpcClient` with an `RpcSource` endpoint
3. Map each RPC method to a typed Swift async function
4. Decode responses into domain types (`Balance`, `TokenAccount`, `TransactionStatus`, etc.)
5. Handle commitment levels and null results explicitly

## Requirements

- iOS 15+ / macOS 12+ (for `URLSession.data(for:)` async)
- Swift 5.7+
- No third-party networking library required (plain `URLSession`)

---

## 1. JSON-RPC Request / Response Types

All Solana RPC calls share the same JSON-RPC 2.0 envelope. The challenge is that `params` is a heterogeneous array, so use `AnyEncodable` to wrap mixed types.

```swift
// AnyEncodable — wraps any Encodable value for use in heterogeneous arrays
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        _encode = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

// JSON-RPC 2.0 request envelope
struct RpcRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [AnyEncodable]
}

// JSON-RPC 2.0 response envelope
struct RpcResponse<T: Decodable>: Decodable {
    let result: T?
    let error: RpcError?
}

struct RpcError: Decodable, Error {
    let code: Int
    let message: String
}
```

---

## 2. Generic RpcClient

```swift
enum RpcClientError: Error {
    case invalidResponse
    case rpcError(RpcError)
    case decodingError(Error)
}

struct RpcSource {
    let url: URL

    // Common public endpoints
    static let mainnetBeta = RpcSource(url: URL(string: "https://api.mainnet-beta.solana.com")!)
    static let devnet       = RpcSource(url: URL(string: "https://api.devnet.solana.com")!)
}

final class RpcClient {
    private let source: RpcSource
    private let session: URLSession
    private let decoder = JSONDecoder()
    private var requestId = 0

    init(source: RpcSource, session: URLSession = .shared) {
        self.source = source
        self.session = session
    }

    func call<T: Decodable>(method: String, params: [AnyEncodable]) async throws -> T {
        requestId += 1
        let request = RpcRequest(id: requestId, method: method, params: params)

        var urlRequest = URLRequest(url: source.url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, _) = try await session.data(for: urlRequest)

        let response: RpcResponse<T>
        do {
            response = try decoder.decode(RpcResponse<T>.self, from: data)
        } catch {
            throw RpcClientError.decodingError(error)
        }

        if let rpcError = response.error {
            throw RpcClientError.rpcError(rpcError)
        }
        guard let result = response.result else {
            throw RpcClientError.invalidResponse
        }
        return result
    }
}
```

---

## 3. RPC Method Reference (Swift)

### getLatestBlockhash — for transaction construction

```swift
struct BlockhashResult: Decodable {
    struct Value: Decodable {
        let blockhash: String
        let lastValidBlockHeight: UInt64
    }
    let value: Value
}

extension RpcClient {
    func getLatestBlockhash(commitment: Commitment = .confirmed) async throws -> BlockhashResult.Value {
        let config: [String: AnyEncodable] = ["commitment": AnyEncodable(commitment.rawValue)]
        let result: BlockhashResult = try await call(
            method: "getLatestBlockhash",
            params: [AnyEncodable(config)]
        )
        return result.value
    }
}
```

### getBalance — SOL balance in lamports

```swift
struct BalanceResult: Decodable {
    let value: UInt64  // lamports
}

extension RpcClient {
    func getBalance(publicKey: String, commitment: Commitment = .confirmed) async throws -> Lamports {
        let config: [String: AnyEncodable] = ["commitment": AnyEncodable(commitment.rawValue)]
        let result: BalanceResult = try await call(
            method: "getBalance",
            params: [AnyEncodable(publicKey), AnyEncodable(config)]
        )
        return result.value
    }
}
```

### getTokenAccountsByOwner — SPL token accounts

```swift
struct TokenAccountsResult: Decodable {
    struct AccountInfo: Decodable {
        let pubkey: String
        let account: AccountData
    }
    struct AccountData: Decodable {
        let data: ParsedAccountData
    }
    struct ParsedAccountData: Decodable {
        let parsed: ParsedInfo
    }
    struct ParsedInfo: Decodable {
        let info: TokenInfo
        let type: String
    }
    struct TokenInfo: Decodable {
        let mint: String
        let owner: String
        let tokenAmount: TokenAmount
    }
    let value: [AccountInfo]
}

extension RpcClient {
    func getTokenAccountsByOwner(owner: String, commitment: Commitment = .confirmed) async throws -> [TokenAccountsResult.AccountInfo] {
        let programId = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"  // SPL Token program
        let filter: [String: AnyEncodable] = ["programId": AnyEncodable(programId)]
        let config: [String: AnyEncodable] = [
            "encoding": AnyEncodable("jsonParsed"),
            "commitment": AnyEncodable(commitment.rawValue)
        ]
        let result: TokenAccountsResult = try await call(
            method: "getTokenAccountsByOwner",
            params: [AnyEncodable(owner), AnyEncodable(filter), AnyEncodable(config)]
        )
        return result.value
    }
}
```

### getSignaturesForAddress — transaction history

```swift
struct SignatureInfo: Decodable {
    let signature: String
    let slot: UInt64
    let blockTime: Int64?
    let err: AnyCodable?   // null = success
    let memo: String?
}

extension RpcClient {
    func getSignaturesForAddress(
        address: String,
        limit: Int = 100,
        before: String? = nil,
        until: String? = nil,
        commitment: Commitment = .confirmed
    ) async throws -> [SignatureInfo] {
        var config: [String: AnyEncodable] = [
            "limit": AnyEncodable(limit),
            "commitment": AnyEncodable(commitment.rawValue)
        ]
        if let before { config["before"] = AnyEncodable(before) }
        if let until  { config["until"]  = AnyEncodable(until)  }

        return try await call(
            method: "getSignaturesForAddress",
            params: [AnyEncodable(address), AnyEncodable(config)]
        )
    }
}
```

### getTransaction — full transaction detail

```swift
// Use AnyCodable for the top-level result — the shape varies significantly.
// Alternatively define a full typed struct for your specific use case.
extension RpcClient {
    /// Returns nil when the transaction is not yet confirmed or has been dropped.
    func getTransaction(signature: String, commitment: Commitment = .confirmed) async throws -> TransactionDetail? {
        let config: [String: AnyEncodable] = [
            "encoding": AnyEncodable("jsonParsed"),
            "commitment": AnyEncodable(commitment.rawValue),
            "maxSupportedTransactionVersion": AnyEncodable(0)
        ]
        // RpcResponse<T?> — result itself can be null (not yet confirmed)
        let result: TransactionDetail? = try await callNullable(
            method: "getTransaction",
            params: [AnyEncodable(signature), AnyEncodable(config)]
        )
        return result
    }

    /// Variant of call() that tolerates a null JSON result without throwing.
    func callNullable<T: Decodable>(method: String, params: [AnyEncodable]) async throws -> T? {
        requestId += 1
        let request = RpcRequest(id: requestId, method: method, params: params)
        var urlRequest = URLRequest(url: source.url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        let (data, _) = try await session.data(for: urlRequest)
        let response = try decoder.decode(RpcResponse<T?>.self, from: data)
        if let rpcError = response.error { throw RpcClientError.rpcError(rpcError) }
        return response.result ?? nil
    }
}
```

### sendTransaction — broadcast signed transaction

```swift
extension RpcClient {
    /// `transactionData` must be a base64-encoded, fully signed transaction.
    func sendTransaction(transactionData: Data, skipPreflight: Bool = false) async throws -> String {
        let base64 = transactionData.base64EncodedString()
        let config: [String: AnyEncodable] = [
            "encoding": AnyEncodable("base64"),
            "skipPreflight": AnyEncodable(skipPreflight)
        ]
        let signature: String = try await call(
            method: "sendTransaction",
            params: [AnyEncodable(base64), AnyEncodable(config)]
        )
        return signature  // returns the transaction signature
    }
}
```

### simulateTransaction — preflight check

```swift
struct SimulationResult: Decodable {
    struct Value: Decodable {
        let err: AnyCodable?
        let logs: [String]?
        let unitsConsumed: UInt64?
    }
    let value: Value
}

extension RpcClient {
    func simulateTransaction(transactionData: Data) async throws -> SimulationResult.Value {
        let base64 = transactionData.base64EncodedString()
        let config: [String: AnyEncodable] = ["encoding": AnyEncodable("base64")]
        let result: SimulationResult = try await call(
            method: "simulateTransaction",
            params: [AnyEncodable(base64), AnyEncodable(config)]
        )
        return result.value
    }
}
```

### getSlot / getBlockHeight — block height polling

```swift
extension RpcClient {
    func getSlot(commitment: Commitment = .confirmed) async throws -> UInt64 {
        let config: [String: AnyEncodable] = ["commitment": AnyEncodable(commitment.rawValue)]
        return try await call(method: "getSlot", params: [AnyEncodable(config)])
    }

    func getBlockHeight(commitment: Commitment = .confirmed) async throws -> UInt64 {
        let config: [String: AnyEncodable] = ["commitment": AnyEncodable(commitment.rawValue)]
        return try await call(method: "getBlockHeight", params: [AnyEncodable(config)])
    }
}
```

---

## 4. Key Solana Types (Swift)

```swift
// Raw lamport value — 1 SOL = 1_000_000_000 lamports
typealias Lamports = UInt64

// Extension to convert lamports to SOL as Decimal
extension Lamports {
    var sol: Decimal { Decimal(self) / 1_000_000_000 }
}

// Opaque base58 string wrappers — validated on construction
struct PublicKey: Hashable, Codable, CustomStringConvertible {
    let base58: String

    init(_ base58: String) throws {
        guard base58.count >= 32 && base58.count <= 44 else {
            throw SolanaError.invalidPublicKey(base58)
        }
        self.base58 = base58
    }

    var description: String { base58 }
}

struct Signature: Hashable, Codable, CustomStringConvertible {
    let base58: String
    var description: String { base58 }
}

// SPL token amount with decimal metadata
struct TokenAmount: Decodable {
    let amount: String          // raw integer as string, e.g. "1000000"
    let decimals: Int
    let uiAmountString: String  // human-readable, e.g. "1.0"

    var uiAmount: Decimal? { Decimal(string: uiAmountString) }
}

// Commitment levels (ordered from least to most final)
enum Commitment: String, Codable {
    case processed  // may be rolled back
    case confirmed  // cluster majority voted
    case finalized  // maximum lockout, will not be rolled back
}

enum SolanaError: Error {
    case invalidPublicKey(String)
    case transactionFailed(String)
    case insufficientFunds
}
```

---

## 5. Base58 Encoding

Solana public keys and signatures are base58-encoded (Bitcoin alphabet: `123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`). There is no built-in Swift support — use one of these options:

**Option A — use `HdWalletKit.Swift`** (already used by EvmKit.Swift, preferred for this project):
```swift
import HdWalletKit
let decoded: Data = Base58.decode(publicKeyString)
let encoded: String = Base58.encode(publicKeyBytes)
```

**Option B — include a minimal Base58 implementation directly in the package:**
```swift
// Sources/SolanaKit/Crypto/Base58.swift
enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let base = BigInt(58)

    static func encode(_ bytes: [UInt8]) -> String { /* ... */ }
    static func decode(_ string: String) throws -> [UInt8] { /* ... */ }
}
```

**Notes:**
- Public keys are 32-byte ed25519 keys encoded as base58 (typically 32–44 chars).
- Signatures are 64-byte values encoded as base58 (typically 87–88 chars).
- Never confuse base58 (Solana/Bitcoin) with base58check (adds a 4-byte checksum).
- `sendTransaction` encodes the serialized transaction as **base64**, not base58.

---

## 6. Common Pitfalls

1. **`sendTransaction` requires base64, not base58** — The serialized transaction wire format must be base64-encoded. Sending base58 returns an encoding error from the RPC node. Always pass `"encoding": "base64"` in the config.

2. **`getTransaction` returns null for unconfirmed transactions** — A transaction that exists on-chain but has not reached the requested commitment level returns `null` as the result (not an error). Use `callNullable()` and poll until non-null. Do not treat null as a failure.

3. **Commitment level mismatches** — `processed` data can be rolled back; use `confirmed` for balances and `finalized` for settled transactions. The Android kit uses `confirmed` as the default; match that behavior.

4. **`TokenAmount.amount` is a string, not an integer** — Even though it represents an integer count of the smallest token unit, the RPC returns it as a JSON string (e.g. `"1000000"`) to avoid 64-bit overflow in JavaScript. Parse with `UInt64(tokenAmount.amount)`.

5. **Rate limiting on public RPC endpoints** — `api.mainnet-beta.solana.com` enforces strict rate limits (40 req/10s). In production, always use a private RPC endpoint (e.g. Helius, QuickNode, Triton). Design `RpcSource` to accept any URL so the consumer can configure it.

6. **`getSignaturesForAddress` is paginated** — It returns at most `limit` results (max 1000). Use the `before` parameter (set to the last signature seen) to page backwards through history. Mirror the Android `TransactionSyncer` pagination logic.

7. **Transaction version support** — Pass `"maxSupportedTransactionVersion": 0` in `getTransaction` config, otherwise versioned transactions (v0, used by many DeFi protocols) return an error.

8. **`getLatestBlockhash` blockhash expiry** — A blockhash is only valid for ~150 slots (~60 seconds). Fetch it immediately before constructing and signing a transaction; do not cache it.

9. **Concurrency safety** — `RpcClient.requestId` is mutable state. If you call `RpcClient` from concurrent `Task`s, protect `requestId` with an actor or use an atomic counter. The id only needs to be unique per session, so a simple monotonic counter is fine.
