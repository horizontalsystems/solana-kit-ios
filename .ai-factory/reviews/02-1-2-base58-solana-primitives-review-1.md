## Code Review Summary

**Files Reviewed:** 4 (Base58.swift, CompactU16.swift, PublicKey.swift, Package.swift diff + SolanaKit.swift deletion)
**Risk Level:** 🟢 Low

### Context Gates

- **ARCHITECTURE.md:** WARN — `PublicKey` is marked `internal` (no access modifier) in this commit but lives in `Models/`. The architecture says "Nothing outside `Kit.swift` and `Signer.swift` should be `public`", which aligns with the `internal` default here. However, `Kit`'s public API will need to expose `PublicKey` in publishers (`AnyPublisher<[FullTokenAccount], Never>` etc.), which will require making it `public` later. This was correctly handled in a subsequent milestone — no issue with this commit.
- **RULES.md:** No file present. WARN (non-blocking).
- **ROADMAP.md:** Milestone 1.2 is marked `[x]` complete. All plan tasks (Base58, CompactU16, PublicKey, scaffold removal) are delivered. Aligned.

### Critical Issues

None.

### Suggestions

**S1: `CompactU16.decode` returns `bytesRead: 0` on empty data — add precondition**
File: `Sources/SolanaKit/Helper/CompactU16.swift`, line 27

If called with empty `Data`, the `for` loop never executes and the function returns `(value: 0, bytesRead: 0)`. Any caller that advances a cursor by `bytesRead` will infinite-loop. The downstream caller in `SolanaSerializer.swift:354` already guards against `bytesRead == 0`, so this hasn't caused a bug *yet*, but `CompactU16` is a foundational primitive that could be called from new code without that guard.

Fix: add `precondition(!data.isEmpty, "CompactU16.decode called with empty data")` at the top of the function, or return a tuple with a clear sentinel/throw. Since this is `internal`, a `precondition` is appropriate — it will crash in debug and signal a programming error.

**S2: `CompactU16.encode` does not validate input range — risk of infinite loop on negative values**
File: `Sources/SolanaKit/Helper/CompactU16.swift`, line 10

The doc states 0–65535, but no validation is enforced. A negative `Int` value would cause an infinite loop: Swift's `>>=` on signed integers is arithmetic (sign-extending), so a negative `remaining` never reaches 0. Values > 65535 would produce >3 bytes, violating the Solana compact-u16 spec and silently creating malformed transactions.

All current callers pass `.count` from arrays (always ≥ 0), so this hasn't triggered. But since this encodes directly into transaction wire format, a `precondition(value >= 0 && value <= 65535)` would prevent subtle serialization bugs from ever reaching the network.

### Positive Notes

- **Base58 algorithm is correct.** Standard big-integer base conversion, handles leading zeros properly, alphabet matches the canonical Bitcoin/sol4k alphabet (58 chars, no 0/O/I/l). Empty input round-trips correctly (`encode(Data()) → ""`, `decode("") → Data()`). No checksum — correct for Solana.
- **CompactU16 algorithm is correct** for valid inputs. Matches Solana's unsigned LEB128 variant. Verified encode/decode round-trips for boundary values: 0, 127, 128, 16383, 16384, 65535.
- **PublicKey is well-designed.** Unifies Android's two separate `PublicKey` types into a single clean type. All conformances (Equatable, Hashable, Codable, CustomStringConvertible, DatabaseValueConvertible) are correct. Error handling in the Base58 init correctly distinguishes `invalidCharacter` vs `invalidPublicKeyLength`. The Codable impl properly wraps errors in `DecodingError.dataCorruptedError` for JSON-RPC compatibility.
- **Well-known constants are all verified** — standard Solana program IDs with correct Base58 encodings. `try!` is safe here since the strings are compile-time constants with known-valid encodings.
- **Clean separation** — `Base58` and `CompactU16` as caseless enum namespaces, `PublicKey` as a value type with extensions. Follows EvmKit conventions (mirrors `RLP.swift` helper pattern and `Address.swift` conformance pattern).
- **Package.swift iOS 14 minimum** is reasonable and compatible with all declared dependencies.
