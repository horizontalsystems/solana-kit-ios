# Plan: 1.1 SPM Package Scaffold

## Context

Create the foundational Swift Package structure for `solana-kit-ios` — the `Package.swift` manifest with all SPM dependencies, the `Sources/SolanaKit/` directory tree matching the architecture spec, and minimal placeholder files so the package resolves and compiles as an empty library. This is the first milestone; nothing exists yet beyond planning docs.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Package manifest

- [x] **Task 1: Create `Package.swift`**
  Files: `Package.swift`
  Create the SPM manifest mirroring EvmKit.Swift's exact format:
  - `swift-tools-version:5.5`
  - `platforms: [.iOS(.v13)]`
  - Single library product named `"SolanaKit"` backed by target `"SolanaKit"`
  - Dependencies (all `.upToNextMajor`):
    - `https://github.com/groue/GRDB.swift.git` from `"6.0.0"` — persistence
    - `https://github.com/horizontalsystems/HdWalletKit.Swift.git` from `"1.2.1"` — BIP44 key derivation (match EvmKit version)
    - `https://github.com/horizontalsystems/HsToolKit.Swift.git` from `"2.0.3"` — networking/logger utilities (match EvmKit version)
    - `https://github.com/horizontalsystems/HsExtensions.Swift.git` from `"1.0.6"` — Swift extensions (match EvmKit version)
    - `https://github.com/bitmark-inc/tweetnacl-swiftwrap.git` from `"1.1.0"` — Ed25519 signing (already a transitive dep in unstoppable-wallet-ios via TonKit)
  - Single `.target(name: "SolanaKit", dependencies: [...])` using `.product(name:package:)` syntax for all deps where product name differs from package name:
    - `.product(name: "GRDB", package: "GRDB.swift")`
    - `.product(name: "HdWalletKit", package: "HdWalletKit.Swift")`
    - `.product(name: "HsToolKit", package: "HsToolKit.Swift")`
    - `.product(name: "HsExtensions", package: "HsExtensions.Swift")`
    - `.product(name: "TweetNacl", package: "tweetnacl-swiftwrap")`
  - No test targets (tests are out of scope for this milestone)

### Phase 2: Directory structure and placeholder files

- [x] **Task 2: Create source directory tree**
  Files: `Sources/SolanaKit/Core/`, `Sources/SolanaKit/Models/`, `Sources/SolanaKit/Database/`, `Sources/SolanaKit/Api/`, `Sources/SolanaKit/Transactions/`
  Create the full directory structure under `Sources/SolanaKit/` matching ARCHITECTURE.md:
  - `Core/` — will hold Kit.swift, Signer.swift, Protocols.swift, SyncManager, BalanceManager, TokenAccountManager, ConnectionManager
  - `Models/` — will hold pure value types (SyncState, RpcSource, FullTransaction, etc.)
  - `Database/` — will hold MainStorage, TransactionStorage
  - `Api/` — will hold RpcClient, ApiSyncer, SolanaFmService
  - `Transactions/` — will hold TransactionManager, TransactionSyncer, PendingTransactionSyncer

- [x] **Task 3: Add `SolanaKit.swift` placeholder so the package compiles**
  Files: `Sources/SolanaKit/SolanaKit.swift`
  Create a minimal top-level file that makes the package compile with `swift build`. This is a namespace placeholder — just an empty enum or a brief comment. SPM requires at least one Swift source file in the target for resolution to succeed. Example:
  ```swift
  // SolanaKit — Solana blockchain SDK for iOS
  // This file exists so the package compiles during scaffolding.
  ```

### Phase 3: Validate

- [x] **Task 4: Resolve dependencies and verify the package builds**
  Run `swift package resolve` followed by `swift build` from the package root. Both must succeed with zero errors. Fix any dependency resolution or target configuration issues until the build is clean.
