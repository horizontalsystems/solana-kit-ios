## Code Review Summary

**Files Reviewed:** 2
**Risk Level:** 🟢 Low

### Context Gates

- **ARCHITECTURE.md:** No violations. `TransactionManager` receives `address` as a plain `String` (value type, not an upward dependency). Filtered publishers derive from the internal `transactionsSubject` and are exposed through `Kit` — matching the "managers own subjects, Kit exposes erased publishers" pattern. All `.send()` calls remain dispatched on `DispatchQueue.main`.
- **RULES.md:** No file present. (WARN — informational)
- **ROADMAP.md:** Milestone 3.6 correctly marked `[x]`. Aligned.

### Critical Issues

None found.

### Suggestions

None.

### Positive Notes

1. **Faithful Android port with correct Kotlin→Swift idiom translation.** The three reactive flows (`allTransactionsFlow`, `solTransactionsFlow`, `splTransactionsFlow`) are accurately mirrored using Combine's `.map` + `.filter` chain. Kotlin's `val incoming = incoming ?: return@map txList` is correctly expressed as `guard let incoming = incoming else { return transactions }`.

2. **`hasSplTransfer` is actually more correct than Android.** Android's implementation uses a non-local `return false` inside the `any { }` lambda (Kotlin inline function), which exits the entire function if ANY transfer has a non-matching mint — skipping remaining transfers that might match. The Swift port uses `contains(where:)` with a local `return false`, which correctly checks all transfers in the list. This is the intended behavior.

3. **`hasSolTransfer` intentionally tightens the `amount > 0` check.** Android only applies `amount > BigDecimal.ZERO` when `incoming` is non-nil, meaning a zero-amount transaction passes when direction is unfiltered. The Swift version applies `amount > 0` unconditionally in the guard. The plan explicitly specifies this behavior ("returns true when `decimalAmount` is non-nil and > 0"), and zero-amount SOL transfers are meaningless in practice.

4. **Correct closure capture semantics.** `incoming` (`Bool?`, value type) is captured by value — frozen at publisher creation time. `[weak self]` on the `TransactionManager` reference avoids retain cycles. When `self` is nil, the closure returns `[]`, which is suppressed by `.filter { !$0.isEmpty }` — no spurious emissions after deallocation.

5. **Clean Kit wiring.** The three public methods on `Kit` are simple delegation — no logic duplication. `Kit.instance()` correctly passes `address` into `TransactionManager`'s init. The public API follows the EvmKit factory-method pattern where each call returns a new derived publisher.

6. **Correct `allTransactionsPublisher` filter logic.** When `incoming` is non-nil, keeps transactions where `hasSolTransfer` matches OR any `tokenTransfer.incoming` matches — exactly matching Android's `hasSolTransfer(fullTransaction, incoming) || fullTransaction.tokenTransfers.any { it.tokenTransfer.incoming == incoming }`.

REVIEW_PASS
