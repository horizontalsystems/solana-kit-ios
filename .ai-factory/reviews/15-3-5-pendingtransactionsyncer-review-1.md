## Code Review Summary

**Files Reviewed:** 4
**Risk Level:** Low

### Context Gates

- **ARCHITECTURE.md:** WARN — `PendingTransactionSyncer` depends directly on `TransactionManager` (concrete type) rather than a protocol, which breaks the "Core may call through protocol interfaces" rule. However, `TransactionSyncer` follows the same pattern (it also takes `TransactionManager` directly), so this is a pre-existing convention in the Transactions layer. Not a regression introduced by this change.
- **RULES.md:** No file present. (WARN — informational)
- **ROADMAP.md:** Milestone 3.5 correctly marked as `[x]`. Aligned.

### Critical Issues

None found.

### Suggestions

None.

### Positive Notes

1. **Faithful Android port.** The three-way branch (confirmed / blockhash-valid / blockhash-expired) correctly mirrors Android `PendingTransactionSyncer.sync()` lines 24-65. The logic, edge cases, and error handling all match.

2. **Intentional improvement over Android.** Using `IRpcApiProvider.sendTransaction` instead of Android's hardcoded mainnet `HttpURLConnection` for re-broadcast is a good design decision that routes through the configured RPC source.

3. **Type safety verified.** `currentBlockHeight` is `Int64`, matching `pendingTx.lastValidBlockHeight` (`Int64`). The `Transaction` constructor calls use all 12 stored properties correctly. `AnyCodable.description` produces a valid `String` for the `error` field. The `hash` primary key with `.replace` conflict policy ensures `Record.update(db)` works correctly on newly constructed instances.

4. **Correct sync lifecycle placement.** `pendingTransactionSyncer.sync()` is placed before the `guard !syncState.syncing` check in `TransactionSyncer.sync()`, ensuring pending transactions are polled on every heartbeat even when the main history sync is already running. This matches Android behavior.

5. **Correct wiring order in Kit.instance().** `PendingTransactionSyncer` is instantiated after its dependencies (`rpcApiProvider`, `transactionStorage`, `transactionManager`) and before its consumer (`TransactionSyncer`). The dependency graph is acyclic and correctly ordered.

6. **`notifyTransactionsUpdate` follows existing patterns.** Dispatches to `DispatchQueue.main` before calling `send()`, matching the existing pattern in `TransactionManager.handle(...)`. Uses `[weak self]` to avoid retain cycles.

7. **Error isolation is correct.** Individual `getTransaction` failures are caught per-transaction (lines 60-64) so one failure doesn't prevent processing remaining pending transactions. `resendTransaction` errors are silently swallowed (best-effort). `getBlockHeight` failure causes early return with no partial state mutation.

REVIEW_PASS
