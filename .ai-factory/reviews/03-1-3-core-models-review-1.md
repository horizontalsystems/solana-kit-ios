# Review: 1.3 Core Models

**Build status:** iOS build succeeds (`xcodebuild -scheme SolanaKit -destination 'generic/platform=iOS'` — BUILD SUCCEEDED). `swift build` fails due to pre-existing macOS platform constraints in upstream dependencies (HsToolKit, HdWalletKit) — unrelated to this milestone.

## Files Reviewed

| File | Status | Verdict |
|------|--------|---------|
| `Sources/SolanaKit/Models/Address.swift` | New | OK |
| `Sources/SolanaKit/Models/SyncState.swift` | New | OK |
| `Sources/SolanaKit/Models/RpcSource.swift` | New | OK |
| `Sources/SolanaKit/Models/BalanceEntity.swift` | New | OK |
| `Sources/SolanaKit/Models/LastBlockHeightEntity.swift` | New | OK |
| `Sources/SolanaKit/Models/InitialSyncEntity.swift` | New | OK |
| `Sources/SolanaKit/Models/PublicKey.swift` | Modified | OK |

## Critical Issues

None.

## Non-Critical Observations

### 1. `Address.ValidationError` is declared but never thrown (minor)

`Address.swift:82-85` defines `ValidationError.invalidAddress`, but the throwing init at line 19 propagates `PublicKey.Error` instead. The plan notes this is "for future validation needs." Not a bug — just unused code. Acceptable since it will be needed when Solana-specific address validation is added (e.g., on-curve checks).

### 2. Force-unwrap in `RpcSource` factory methods (acceptable)

`RpcSource.swift:56` — `URL(string: "https://solana-mainnet.g.alchemy.com/v2/\(apiKey)")!` will crash if `apiKey` contains URL-invalid characters (spaces, etc.). In practice, Alchemy API keys are alphanumeric and this is safe. This matches EvmKit's identical pattern (e.g., `URL(string: "https://mainnet.infura.io/v3/\(projectId)")!`). Consistent and acceptable.

### 3. GRDB entities require migrations to function at runtime (expected)

`BalanceEntity`, `LastBlockHeightEntity`, and `InitialSyncEntity` define table names and columns but no database migrations. These entities will only work once `MainStorage` (milestone 1.5) creates the tables with proper primary key constraints and `onConflict: .replace` for the singleton-row `save()` pattern. This is the correct separation — entities define shape, storage defines schema.

### 4. `SyncState.description` for `.syncing` differs from EvmKit (cosmetic)

`SyncState.swift:56` uses `progress.map { String($0) } ?? "?"` for the nil-progress case, while EvmKit uses `"syncing \(progress ?? 0)"`. SolanaKit outputs `"syncing ?"` vs EvmKit's `"syncing 0.0"` for indeterminate progress. Cosmetic only — no functional impact.

### 5. `PublicKey` well-known program IDs remain `internal` (correct)

`PublicKey.swift:50-54` — The static program IDs (`systemProgramId`, `tokenProgramId`, etc.) are `internal` access. This is correct per the architecture: only `Kit` and `Signer` are public. Program IDs are consumed internally by transaction serialization (milestone 4.4).

## Correctness Checks

- **`Decimal(lamports) / 1_000_000_000`**: Verified — `Decimal` integer literal inference works correctly. Tested with large values (9,999,999,999,999,999 lamports) and precision is preserved to 9 decimal places.
- **`Int64` range for lamports**: Max SOL supply ~580M = ~5.8 * 10^17 lamports, well within Int64 max (~9.2 * 10^18).
- **`Int64` range for block height**: Current Solana slot ~280M. No overflow risk.
- **GRDB `Record` pattern**: All three entities follow EvmKit's `BlockchainState`/`AccountState` pattern exactly (singleton-row with hardcoded primaryKey string, `Columns` enum, `required init(row:)`, `encode(to:)`).
- **`Address` delegates correctly to `PublicKey`**: All conformances (Equatable, Hashable, DatabaseValueConvertible, Codable) correctly delegate to the underlying `PublicKey`, avoiding duplicate logic.
- **`SyncState` Equatable**: Manual implementation handles the non-Equatable `Error` type via string interpolation comparison — same approach as EvmKit.

## Architecture Compliance

- All public types (`Address`, `SyncState`, `SyncError`, `RpcSource`) are correctly `public`.
- All GRDB entities (`BalanceEntity`, `LastBlockHeightEntity`, `InitialSyncEntity`) are correctly `internal`.
- Models layer has no dependencies on Core, Infrastructure, or Kit layers — only `Foundation` and `GRDB`.
- `PublicKey` visibility upgrade to `public` is necessary and correct — `Address.publicKey` is a public property.

REVIEW_PASS
