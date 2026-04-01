# Project Overview

**Purpose**: Swift Package porting `solana-kit-android` (Kotlin) to iOS, following `EvmKit.Swift` patterns. Provides Solana blockchain integration (balance, transactions, token accounts, signing, Jupiter swaps).

**Tech Stack**: Swift 5.5+, SPM, iOS 14+, GRDB (persistence), Combine (reactive), HdWalletKit (BIP44), HsToolKit (networking), CryptoKit (Ed25519 signing).

**Structure**:
- `Core/` — Kit facade, Signer, SyncManager, BalanceManager, TokenAccountManager, ConnectionManager
- `Api/` — RPC client, ApiSyncer, Jupiter API, JSON-RPC definitions
- `Transactions/` — TransactionSyncer, TransactionManager, PendingTransactionSyncer
- `Database/` — MainStorage, TransactionStorage (GRDB)
- `Models/` — Data models, RPC response types
- `Programs/` — SystemProgram, TokenProgram, AssociatedTokenAccount, ComputeBudget
- `Helper/` — Serialization, Base58, layouts
