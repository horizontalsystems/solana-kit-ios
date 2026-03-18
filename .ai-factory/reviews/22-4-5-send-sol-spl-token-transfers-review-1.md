# Review: 4.5 Send SOL & SPL Token Transfers

## Files Reviewed

| File | Status | Type |
|------|--------|------|
| `Sources/SolanaKit/Programs/ComputeBudgetProgram.swift` | New | Instruction builder |
| `Sources/SolanaKit/Transactions/TransactionManager.swift` | Modified | Send pipeline + wiring |
| `Sources/SolanaKit/Core/Kit.swift` | Modified | Public API + SendError |

## Dependency Verification

Every external type/method referenced in the new code was checked against its source definition:

| Call site | Target | Signature match |
|-----------|--------|-----------------|
| `PublicKey.computeBudgetProgramId` | `PublicKey.swift:55` | OK |
| `SolanaSerializer.serializeMessage(feePayer:instructions:recentBlockhash:)` | `SolanaSerializer.swift:262` | OK |
| `SolanaSerializer.buildTransaction(feePayer:instructions:recentBlockhash:signatures:)` | `SolanaSerializer.swift:280` | OK |
| `signer.sign(data:) -> Data` | `Signer.swift:41` | OK |
| `rpcApiProvider.getLatestBlockhash() -> RpcBlockhashResponse` | `Protocols.swift:255` | OK |
| `rpcApiProvider.sendTransaction(serializedBase64:) -> String` | `Protocols.swift:251` | OK |
| `rpcApiProvider.getMultipleAccounts(addresses:) -> [BufferInfo?]` | `Protocols.swift:259` | OK |
| `RpcBlockhashResponse.blockhash: String` | `RpcBlockhashResponse.swift:5` | OK |
| `RpcBlockhashResponse.lastValidBlockHeight: Int64` | `RpcBlockhashResponse.swift:6` | OK |
| `SystemProgram.transfer(from:to:lamports:)` | `SystemProgram.swift:26` | OK |
| `TokenProgram.transfer(source:destination:authority:amount:)` | `TokenProgram.swift:28` | OK |
| `AssociatedTokenAccountProgram.associatedTokenAddress(wallet:mint:)` | `AssociatedTokenAccountProgram.swift:23` | OK |
| `AssociatedTokenAccountProgram.createIdempotent(payer:associatedToken:owner:mint:)` | `AssociatedTokenAccountProgram.swift:58` | OK |
| `PublicKey(_ base58String:)` | `PublicKey.swift:25` | OK |
| `PublicKey.base58: String` | `PublicKey.swift:37` | OK |
| `PublicKey: Equatable` | `PublicKey.swift:148` | OK |
| `storage.fullTokenAccount(mintAddress:) -> FullTokenAccount?` | `Protocols.swift:57` | OK |
| `storage.mintAccount(address:) -> MintAccount?` | `Protocols.swift:47` | OK |
| `storage.save(transactions:)` | `Protocols.swift:36` | OK |
| `storage.save(tokenTransfers:)` | `Protocols.swift:43` | OK |
| `tokenAccount.address: String` (ATA address) | `TokenAccount.swift:10` doc: "SPL token account address (ATA address)" | OK |

## ComputeBudgetProgram.swift

**Correctness:** OK. Discriminator bytes (`0x02` for SetComputeUnitLimit, `0x03` for SetComputeUnitPrice) are correct per the Solana Compute Budget Program spec. Data layouts: 5 bytes (1 + UInt32 LE) and 9 bytes (1 + UInt64 LE) respectively. No account keys needed. Uses `PublicKey.computeBudgetProgramId` which exists at `PublicKey.swift:55`.

**No issues.**

## TransactionManager.swift — sendSol

**Correctness:** OK. The pipeline faithfully reproduces Android's `TransactionManager.sendSol()`:
1. Fetch blockhash via `getLatestBlockhash()` with `commitment: "finalized"` (set in `GetLatestBlockhashJsonRpc`).
2. Build instructions: ComputeBudget (CU limit + CU price) + SystemProgram.transfer.
3. Serialize message, sign, build full wire transaction, base64-encode, broadcast.
4. Persist as pending with blockhash + lastValidBlockHeight + base64Encoded for `PendingTransactionSyncer` retry.
5. Emit via `transactionsSubject` on `DispatchQueue.main`.

**fee string:** `"\(Kit.fee)"` where `Kit.fee = Decimal(string: "0.000155")!`. `Decimal.description` returns `"0.000155"`. OK — matches Android's hardcoded `BigDecimal(0.000155)`.

**No issues.**

## TransactionManager.swift — sendSpl

**Correctness:** OK. Reproduces Android's `TransactionManager.sendSpl()`:
1. Sender ATA from local DB (`storage.fullTokenAccount(mintAddress:)`) — same as Android's `tokenAccountManager.getFullTokenAccountByMintAddress(mintAddressString)`.
2. Recipient ATA derivation via PDA — same as Android's `findSPLTokenDestinationAddress`.
3. ATA existence check via `getMultipleAccounts` (single address) — functionally equivalent to Android's `getAccountInfo`. The double-Optional unwrap `recipientATAAccounts.first.flatMap { $0 }` is correct: `[nil].first` is `Optional(nil)`, `.flatMap { $0 }` is `nil`.
4. Conditional `createIdempotent` instruction — safe even if ATA is created between our check and transaction processing (no-op by design).
5. Same-address guard (`senderATA != recipientATA`) — matches Android.
6. Persist Transaction + TokenTransfer separately — matches Android. SPL transactions don't set `from`/`to`/`amount` on the base Transaction record, only on TokenTransfer. This is consistent with `handle()` merge logic.
7. Fallback MintAccount construction from `tokenAccount.decimals` if `storage.mintAccount()` returns nil — defensive and correct.

**No issues.**

## TransactionManager.swift — serializeSignAndSend

**Observation (non-blocking):** The helper calls `SolanaSerializer.serializeMessage(...)` to get message bytes for signing, then calls `SolanaSerializer.buildTransaction(...)` which internally re-compiles the same instructions via `compile(...)`. This means the message is compiled twice with identical inputs. Since `compile()` is deterministic (insertion-ordered dedup, deterministic grouping), the message bytes are identical both times. Functionally correct, but performs redundant work.

An alternative would use the lower-level API:
```swift
let compiled = try SolanaSerializer.compile(feePayer:instructions:recentBlockhash:)
let messageBytes = SolanaSerializer.serialize(message: compiled)
let signature = try signer.sign(data: messageBytes)
let txData = try SolanaSerializer.serialize(signatures: [signature], message: compiled)
```

This is a minor efficiency improvement — not a correctness issue. Deferring to Phase 4.6 or later is fine.

## Kit.swift — Public API

**Correctness:** OK. `sendSol` and `sendSpl` are thin pass-throughs to `TransactionManager`. `SendError` is a well-scoped public enum with three actionable cases. Factory wiring updated to pass `rpcApiProvider` to `TransactionManager`. No changes to init parameter list of `Kit` (rpcApiProvider was already passed; only the `TransactionManager` construction call changed).

**No issues.**

## Kit.swift — SendError placement

`SendError` is defined as a top-level `public enum` at the bottom of `Kit.swift`. It's thrown by `TransactionManager` (same module — no import needed) and propagated through `Kit`. Accessible to external consumers via the `SolanaKit` module. OK.

## Thread Safety

- All `transactionsSubject.send()` calls dispatch on `DispatchQueue.main`. Matches the codebase convention established in `handle()` and `notifyTransactionsUpdate()`.
- `sendSol`/`sendSpl` are `async` — callers must `await`, preventing concurrent mutation of the method body. The underlying `rpcApiProvider.getLatestBlockhash()`/`sendTransaction()` are also `async` — no blocking.
- No shared mutable state is accessed without synchronization.

## PendingTransactionSyncer Compatibility

The pending `Transaction` records store:
- `blockHash` — for expiry check (`currentBlockHeight <= pendingTx.lastValidBlockHeight`)
- `lastValidBlockHeight` — from `RpcBlockhashResponse`
- `base64Encoded` — the full signed transaction for re-broadcast via `resendTransaction(base64Encoded:)`
- `retryCount = 0` — incremented by PendingTransactionSyncer on each re-broadcast

All four fields are correctly populated. `PendingTransactionSyncer.sync()` will pick up these records on the next block-height heartbeat and handle retry/expiry. OK.

## Summary

| Severity | Count | Details |
|----------|-------|---------|
| Critical | 0 | — |
| Bug | 0 | — |
| Suggestion | 1 | `serializeSignAndSend` compiles the message twice; could use lower-level API to compile once (non-blocking, deferred) |

REVIEW_PASS
