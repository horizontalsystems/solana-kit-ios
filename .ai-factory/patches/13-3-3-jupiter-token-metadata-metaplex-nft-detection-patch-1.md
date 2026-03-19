# Patch: 13-3-3 Jupiter Token Metadata + Metaplex NFT Detection

Addresses all issues from `reviews/13-3-3-jupiter-token-metadata-metaplex-nft-detection-review-1.md`.

---

## Fix 1 (Critical): `NftClient.swift` — missing `.hs` namespace on `chunked(into:)`

**File:** `Sources/SolanaKit/Api/NftClient.swift`
**Problem:** Line 53 calls `pdaMappings.chunked(into: chunkSize)` directly on `Array`. Swift's standard library has no such method. `HsExtensions.Swift` provides it under the `.hs` namespace (`array.hs.chunked(into:)`). This is a compile-time error that blocks the entire NFT detection pipeline.
**Impact:** `NftClient` cannot compile, so `TokenAccountManager.sync()` and `TransactionSyncer.resolveMintAccounts()` both fail to build. All Metaplex metadata enrichment (NFT detection, name/symbol/uri, collection address) is dead.

### Change 1a: Add `import HsExtensions` at the top of the file

```
File: Sources/SolanaKit/Api/NftClient.swift
Line: 1
```

**Before:**
```swift
import Foundation
```

**After:**
```swift
import Foundation
import HsExtensions
```

### Change 1b: Use `.hs.chunked(into:)` instead of `.chunked(into:)`

```
File: Sources/SolanaKit/Api/NftClient.swift
Line: 53
```

**Before:**
```swift
        for chunk in pdaMappings.chunked(into: chunkSize) {
```

**After:**
```swift
        for chunk in pdaMappings.hs.chunked(into: chunkSize) {
```

---

## Fix 2 (Suggestion): Extract duplicate `readLE` into shared extension

**Files:**
- `Sources/SolanaKit/Helper/SplMintLayout.swift` (lines 90–100)
- `Sources/SolanaKit/Helper/MetaplexMetadataLayout.swift` (lines 191–200)
- `Sources/SolanaKit/Helper/Data+ReadLE.swift` (new file)

**Problem:** Both `SplMintLayout.swift` and `MetaplexMetadataLayout.swift` define an identical `private extension Data { func readLE<T: FixedWidthInteger>(offset:) -> T }`. This is unnecessary duplication that will grow as more binary parsers are added.

### Change 2a: Create shared extension file

```
File: Sources/SolanaKit/Helper/Data+ReadLE.swift (NEW)
```

**Content:**
```swift
import Foundation

extension Data {
    /// Reads a little-endian integer of type `T` starting at `offset`.
    func readLE<T: FixedWidthInteger>(offset: Int) -> T {
        let size = MemoryLayout<T>.size
        return subdata(in: offset ..< offset + size).withUnsafeBytes { ptr in
            T(littleEndian: ptr.loadUnaligned(as: T.self))
        }
    }
}
```

### Change 2b: Remove private `readLE` from `SplMintLayout.swift`

```
File: Sources/SolanaKit/Helper/SplMintLayout.swift
Lines: 89–100 (delete)
```

**Before:**
```swift
}

// MARK: - Data helpers

private extension Data {
    /// Reads a little-endian integer of type `T` starting at `offset`.
    func readLE<T: FixedWidthInteger>(offset: Int) -> T {
        let size = MemoryLayout<T>.size
        return subdata(in: offset ..< offset + size).withUnsafeBytes { ptr in
            T(littleEndian: ptr.loadUnaligned(as: T.self))
        }
    }
}
```

**After:**
```swift
}
```

### Change 2c: Remove private `readLE` from `MetaplexMetadataLayout.swift`, keep `readBorshString`

```
File: Sources/SolanaKit/Helper/MetaplexMetadataLayout.swift
Lines: 191–200
```

**Before:**
```swift
// MARK: - Data helpers

private extension Data {
    /// Reads a little-endian integer of type `T` starting at `offset`.
    func readLE<T: FixedWidthInteger>(offset: Int) -> T {
        let size = MemoryLayout<T>.size
        return subdata(in: offset ..< offset + size).withUnsafeBytes { ptr in
            T(littleEndian: ptr.loadUnaligned(as: T.self))
        }
    }

    /// Reads a Borsh-encoded string (u32 length prefix + UTF-8 bytes), trims null bytes,
```

**After:**
```swift
// MARK: - Data helpers

private extension Data {
    /// Reads a Borsh-encoded string (u32 length prefix + UTF-8 bytes), trims null bytes,
```

---

## Fix 3 (Suggestion): Align DDL conflict policy with model intent

**File:** `Sources/SolanaKit/Database/TransactionStorage.swift`
**Problem:** Line 88 creates the `mintAccounts` primary key with `onConflict: .ignore`, but `MintAccount.persistenceConflictPolicy` is `.replace`. The model's policy wins at the SQL statement level, so runtime behavior is correct. But the DDL is misleading — it suggests inserts silently skip duplicates when in fact `save()` replaces them.

### Change 3a: Update DDL to `.replace`

```
File: Sources/SolanaKit/Database/TransactionStorage.swift
Line: 88
```

**Before:**
```swift
                t.primaryKey([MintAccount.Columns.address.name], onConflict: .ignore)
```

**After:**
```swift
                t.primaryKey([MintAccount.Columns.address.name], onConflict: .replace)
```

**Migration note:** This change only affects the DDL for **new** database files. Existing databases already have the table created with `.ignore`. Since GRDB's record-level `persistenceConflictPolicy` overrides the DDL anyway, existing databases will behave identically. No data migration is needed.

---

## Summary

| # | Severity | File | Fix |
|---|----------|------|-----|
| 1 | **Critical** | `Api/NftClient.swift` | Add `import HsExtensions`, change `.chunked(into:)` to `.hs.chunked(into:)` |
| 2 | Suggestion | `Helper/SplMintLayout.swift`, `Helper/MetaplexMetadataLayout.swift` | Extract shared `Data.readLE` to `Helper/Data+ReadLE.swift` |
| 3 | Suggestion | `Database/TransactionStorage.swift` | Change DDL `onConflict: .ignore` to `.replace` for `mintAccounts` PK |
