# Plan: Send SOL & SPL Token Transfers

## Context
Implement the end-to-end send pipeline as two public `async throws` methods on `Kit` (`sendSol` and `sendSpl`) that build instructions, compose and sign a transaction, broadcast via RPC, and persist a pending `FullTransaction` for tracking by the existing `PendingTransactionSyncer`. This wires together all existing infrastructure (SolanaSerializer, SystemProgram, TokenProgram, AssociatedTokenAccountProgram, Signer, RpcApiProvider) into a cohesive send flow matching Android's `TransactionManager.sendSol` / `sendSpl`.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: ComputeBudgetProgram Instructions

- [x] **Task 1: Create ComputeBudgetProgram instruction builder**
  Files: `Sources/SolanaKit/Programs/ComputeBudgetProgram.swift`
  Create a new `ComputeBudgetProgram` enum (caseless namespace, matches `SystemProgram` / `TokenProgram` pattern) with two static methods:
  - `setComputeUnitLimit(units: UInt32) -> TransactionInstruction` — discriminator byte `0x02` + UInt32 LE (5 bytes total data). No account keys. Uses `PublicKey.computeBudgetProgramId`.
  - `setComputeUnitPrice(microLamports: UInt64) -> TransactionInstruction` — discriminator byte `0x03` + UInt64 LE (9 bytes total data). No account keys.
  Follow the exact same file structure as `SystemProgram.swift` and `TokenProgram.swift`. Reference: Android `ComputeBudgetProgram.kt` uses `Long` (8 bytes) for both values, but the on-chain program actually expects UInt32 for compute unit limit (instruction discriminator 2) and UInt64 for compute unit price (instruction discriminator 3). Use the correct types.

### Phase 2: TransactionManager Send Methods

- [x] **Task 2: Add `sendSol` to TransactionManager** (depends on Task 1)
  Files: `Sources/SolanaKit/Transactions/TransactionManager.swift`
  Add an `async throws` method `sendSol(toAddress: String, amount: UInt64, signer: Signer) -> FullTransaction` that implements the full SOL send pipeline:
  1. Fetch recent blockhash via `rpcApiProvider.getLatestBlockhash()` — store both `blockhash` and `lastValidBlockHeight`.
  2. Build instruction array: `ComputeBudgetProgram.setComputeUnitLimit(units: 300_000)` + `ComputeBudgetProgram.setComputeUnitPrice(microLamports: 500_000)` + `SystemProgram.transfer(from: senderPublicKey, to: recipientPublicKey, lamports: amount)`.
  3. Serialize the message: `SolanaSerializer.serializeMessage(feePayer:instructions:recentBlockhash:)`.
  4. Sign: `signer.sign(data: messageBytes)` — produces 64-byte Ed25519 signature.
  5. Build full wire transaction: `SolanaSerializer.buildTransaction(feePayer:instructions:recentBlockhash:signatures:)`.
  6. Base64-encode and broadcast: `rpcApiProvider.sendTransaction(serializedBase64:)` — returns the transaction signature (hash).
  7. Construct a `Transaction` record with: `hash` from broadcast result, `timestamp` = `Date().timeIntervalSince1970`, `fee` = `Kit.fee` as String, `from` = sender address, `to` = recipient address, `amount` = amount as String, `pending = true`, `blockHash`, `lastValidBlockHeight`, `base64Encoded` = the base64 string sent to RPC, `retryCount = 0`.
  8. Persist via `storage.save(transactions:)` and emit via `transactionsSubject.send()` on `DispatchQueue.main`.
  9. Return `FullTransaction(transaction:, tokenTransfers: [])`.

  This requires `TransactionManager` to receive `rpcApiProvider: IRpcApiProvider` as a new dependency (add to init and store as private property). Follow the same pattern as `PendingTransactionSyncer` which already holds `rpcApiProvider`.

- [x] **Task 3: Add `sendSpl` to TransactionManager** (depends on Task 1)
  Files: `Sources/SolanaKit/Transactions/TransactionManager.swift`, `Sources/SolanaKit/Core/Protocols.swift`
  Add an `async throws` method `sendSpl(mintAddress: String, toAddress: String, amount: UInt64, signer: Signer) -> FullTransaction`:
  1. Look up the sender's existing token account from local storage via `storage.fullTokenAccount(mintAddress:)`. Throw an error if not found (same as Android).
  2. Derive the recipient's ATA address: `AssociatedTokenAccountProgram.associatedTokenAddress(wallet: recipientPublicKey, mint: mintPublicKey)`.
  3. Check whether the recipient's ATA already exists: call `rpcApiProvider.getMultipleAccounts(addresses: [recipientATA.base58])` and check if the result is non-nil. (Use `getMultipleAccounts` with a single address since there's no `getAccountInfo` RPC method implemented. This is a standard pattern — Android uses `getAccountInfo` but `getMultipleAccounts` with one address is equivalent.)
  4. Fetch recent blockhash via `rpcApiProvider.getLatestBlockhash()`.
  5. Build instruction array:
     - `ComputeBudgetProgram.setComputeUnitLimit(units: 300_000)`
     - `ComputeBudgetProgram.setComputeUnitPrice(microLamports: 500_000)`
     - If ATA does not exist: `AssociatedTokenAccountProgram.createIdempotent(payer: senderPublicKey, associatedToken: recipientATA, owner: recipientPublicKey, mint: mintPublicKey)`
     - `TokenProgram.transfer(source: senderATA, destination: recipientATA, authority: senderPublicKey, amount: amount)` — use basic `transfer` (not `transferChecked`) to match Android's `TokenProgram.transfer` usage.
  6. Serialize message → sign → build wire transaction → base64-encode → broadcast (same steps 3-6 as `sendSol`).
  7. Construct a `Transaction` record with `pending = true` (no `from`/`to`/`amount` on the base transaction — SPL details go in token transfers, matching Android).
  8. Construct a `TokenTransfer` record: `transactionHash`, `mintAddress`, `incoming = false`, `amount` as String. Look up the `MintAccount` from storage for the `FullTokenTransfer`.
  9. Persist transaction and token transfer. Emit `FullTransaction` via `transactionsSubject`.
  10. Return the `FullTransaction`.

  Also add a guard that sender ATA != recipient ATA (same address check, matching Android's "Same send and destination address" error).

- [x] **Task 4: Wire `rpcApiProvider` into TransactionManager** (depends on Tasks 2-3)
  Files: `Sources/SolanaKit/Transactions/TransactionManager.swift`, `Sources/SolanaKit/Core/Kit.swift`
  Update `TransactionManager.init` to accept `rpcApiProvider: IRpcApiProvider` as a new parameter. Update `Kit.instance()` factory to pass `rpcApiProvider` when constructing `TransactionManager`. The `TransactionManager` currently receives only `address` and `storage` — add `rpcApiProvider` alongside them. This is a minimal wiring change.

### Phase 3: Kit Public API

- [x] **Task 5: Add `sendSol` and `sendSpl` public methods to Kit** (depends on Task 4)
  Files: `Sources/SolanaKit/Core/Kit.swift`
  Add two public `async throws` methods on `Kit`:
  - `public func sendSol(toAddress: String, amount: UInt64, signer: Signer) async throws -> FullTransaction` — delegates to `transactionManager.sendSol(...)`.
  - `public func sendSpl(mintAddress: String, toAddress: String, amount: UInt64, signer: Signer) async throws -> FullTransaction` — delegates to `transactionManager.sendSpl(...)`.

  These are thin pass-through methods matching the Android `SolanaKit.sendSol` / `SolanaKit.sendSpl` pattern. The `Signer` is passed through (not owned by Kit) — callers construct their own Signer instance and pass it in, same as Android.

  Also add a `public enum SendError: Error` with cases for common failures: `case tokenAccountNotFound(String)`, `case sameSourceAndDestination`, `case invalidAddress(String)`. These are thrown by TransactionManager and propagated through Kit.

- [x] **Task 6: Extract priority fee instructions as a helper** (depends on Task 1)
  Files: `Sources/SolanaKit/Transactions/TransactionManager.swift`
  Add a private helper method `priorityFeeInstructions() -> [TransactionInstruction]` on `TransactionManager` that returns the two ComputeBudget instructions with hardcoded values (300,000 CU limit, 500,000 microLamports/CU price — matching Android's `TransactionManager.priorityFeeInstructions()`). This avoids duplicating the instruction construction in both `sendSol` and `sendSpl`. Call this helper from both send methods.

## Commit Plan
- **Commit 1** (after Task 1): "Add ComputeBudgetProgram instruction builder for priority fees"
- **Commit 2** (after Tasks 2-4, 6): "Implement sendSol and sendSpl on TransactionManager with full send pipeline"
- **Commit 3** (after Task 5): "Expose sendSol and sendSpl as public Kit API methods"
