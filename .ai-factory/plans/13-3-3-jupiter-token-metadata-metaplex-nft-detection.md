# Plan: Jupiter Token Metadata + Metaplex NFT Detection

## Context

Add two token metadata sources that the Android kit uses: (1) a `JupiterApiService` REST client for fetching token name/symbol/decimals from the Jupiter API, and (2) Metaplex on-chain metadata parsing via RPC for NFT detection (token standard, collection address). These replace the placeholder SolanaFM references in existing code and enhance the basic `decimals==0 && supply==1` heuristic already in `SplMintLayout.isNft` with full Metaplex token-standard checks.

## Settings
- Testing: no
- Logging: minimal
- Docs: no

## Tasks

### Phase 1: Metaplex On-Chain Metadata (RPC-based NFT detection)

- [x] **Task 1: Add Metaplex Token Metadata program ID and PDA derivation to `PublicKey`**
  Files: `Sources/SolanaKit/Models/PublicKey.swift`
  Add the Metaplex Token Metadata program ID as a static constant: `metaplexTokenMetadataProgramId = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"`. Add a `static func metadataPDA(mintPublicKey: PublicKey) throws -> PublicKey` method that derives the Metaplex metadata PDA using `findProgramAddress(seeds: ["metadata", metaplexTokenMetadataProgramId.bytes, mintPublicKey.bytes], programId: metaplexTokenMetadataProgramId)`. Implement the `findProgramAddress` helper as a static method on `PublicKey` (SHA-256 hash loop with bump seed, matching Solana's `createProgramAddress` spec). Reference: Android uses `MetadataAccount.pda(mintKey)` from the Metaplex SDK — we implement the same derivation natively.

- [x] **Task 2: Create `MetaplexMetadataLayout` binary parser**
  Files: `Sources/SolanaKit/Helper/MetaplexMetadataLayout.swift` (new file)
  Parse the Metaplex Metadata Account binary layout returned by `getMultipleAccounts` for metadata PDAs. Fields to extract: `key` (1 byte), `updateAuthority` (32 bytes), `mint` (32 bytes), `name` (4-byte length prefix + UTF-8 string, trimmed of null bytes), `symbol` (4-byte length prefix + UTF-8), `uri` (4-byte length prefix + UTF-8), then skip `sellerFeeBasisPoints` (u16) + `creators` (optional, variable length — use `hasCreators` bool + creator count + 34 bytes each), `collection` (optional: `hasCollection` bool → 1-byte `verified` flag + 32-byte key), `tokenStandard` (optional: `hasTokenStandard` bool → 1-byte enum). Define a `MetaplexTokenStandard` enum: `.fungible(0)`, `.nonFungible(1)`, `.fungibleAsset(2)`, `.nonFungibleEdition(3)`, `.programmableNonFungible(4)`. Follow the `SplMintLayout` pattern — `init(data: Data) throws`, use the existing `Data.readLE` extension. This is the Swift equivalent of Android's `MetadataAccount` (from the Metaplex SDK), reimplemented from the binary spec since there's no Swift Metaplex SDK.

- [x] **Task 3: Create `NftClient` for batch Metaplex metadata fetching**
  Files: `Sources/SolanaKit/Api/NftClient.swift` (new file), `Sources/SolanaKit/Core/Protocols.swift`
  Create `NftClient` class that takes an `IRpcApiProvider` dependency. Primary method: `func findAllByMintList(mintAddresses: [String]) async throws -> [String: MetaplexMetadataLayout]` — derives the metadata PDA for each mint address (via `PublicKey.metadataPDA`), fetches all PDAs via `rpcApiProvider.getMultipleAccounts` in chunks of 100 (reuse the existing `GetMultipleAccountsJsonRpc`), parses each non-nil `BufferInfo` with `MetaplexMetadataLayout(data:)`, filters to accounts where `owner == PublicKey.metaplexTokenMetadataProgramId.base58`, and returns a dictionary keyed by mint address. Add `INftClient` protocol to `Protocols.swift`: `func findAllByMintList(mintAddresses: [String]) async throws -> [String: MetaplexMetadataLayout]`. Mirror Android's `NftClient.kt` logic exactly — chunk size 100, PDA derivation, `getMultipleAccounts`, filter by owner.

- [x] **Task 4: Upgrade NFT detection in `TokenAccountManager` with Metaplex metadata**
  Files: `Sources/SolanaKit/Core/TokenAccountManager.swift`, `Sources/SolanaKit/Core/Protocols.swift`
  Add `nftClient: INftClient` as a new dependency on `TokenAccountManager` (injected in init). In `sync()`, after fetching new mint accounts via `getMultipleAccounts` (step 4, around line 88-103), add a call to `nftClient.findAllByMintList(mintAddresses:)` for the same new mint addresses. Replace the current simple `layout.isNft` assignment with the full Android `getMintAccounts()` logic: (1) `decimals != 0 → false`, (2) `supply == 1 && mintAuthority == nil → true`, (3) `metadataAccount.tokenStandard == .nonFungible → true`, (4) `metadataAccount.tokenStandard == .fungibleAsset → true`, (5) `metadataAccount.tokenStandard == .nonFungibleEdition → true`, (6) else `false`. Extract collection address from verified Metaplex collection field. Populate `MintAccount.name`, `.symbol`, `.uri`, `.collectionAddress` from the metadata. Also update `MintAccount`'s conflict policy from `.ignore` to `.replace` so that enrichment data can be written to existing records (or add an `updateMintAccount` method to storage that explicitly updates metadata fields). Update `ITransactionStorage` protocol if adding a new storage method.

### Phase 2: Jupiter REST API Service

- [x] **Task 5: Create `JupiterApiService` REST client**
  Files: `Sources/SolanaKit/Api/JupiterApiService.swift` (new file), `Sources/SolanaKit/Core/Protocols.swift`
  Create `JupiterApiService` class with a `NetworkManager` (HsToolKit) dependency and an optional API key string. Endpoint: `GET https://api.jup.ag/tokens/v2/search?query=<mintAddress>`. If an API key is provided, include `x-api-key` header. Define a private `JupiterToken` Codable struct with fields: `address: String`, `name: String`, `symbol: String`, `decimals: Int`. The response is a JSON array `[JupiterToken]`. Primary method: `func tokenInfo(mintAddress: String) async throws -> TokenInfo` — fetches the endpoint, takes the first result, maps to `TokenInfo(name:symbol:decimals:)`. Create a new `TokenInfo` model struct in `Sources/SolanaKit/Models/TokenInfo.swift`. Add `IJupiterApiService` protocol to `Protocols.swift`: `func tokenInfo(mintAddress: String) async throws -> TokenInfo`. Follow the EvmKit `EtherscanTransactionProvider` pattern — own `NetworkManager`, use `networkManager.fetchData(url:method:.get:parameters:responseCacherBehavior:.doNotCache)` then decode with `JSONDecoder`. Throw a descriptive error if the response array is empty.

- [x] **Task 6: Wire `NftClient` and `JupiterApiService` into `Kit.instance()`**
  Files: `Sources/SolanaKit/Core/Kit.swift`
  In `Kit.instance(address:rpcSource:walletId:)`: (1) Create `let nftClient = NftClient(rpcApiProvider: rpcApiProvider)` after the `rpcApiProvider` initialization. (2) Create `let jupiterApiService = JupiterApiService(networkManager: NetworkManager(logger: nil))` — use a separate `NetworkManager` instance (standard EvmKit pattern: each service gets its own). (3) Pass `nftClient` to `TokenAccountManager`'s init. (4) Store `jupiterApiService` on `Kit` as a private let for future use (it will be consumed by `TransactionSyncer` in milestone 3.4 and potentially exposed as `TokenProvider`). Update `Kit`'s private init to accept the new dependencies.

## Commit Plan
- **Commit 1** (after tasks 1-3): "Add Metaplex PDA derivation and NftClient for on-chain NFT metadata"
- **Commit 2** (after tasks 4-6): "Integrate Metaplex NFT detection into TokenAccountManager and add Jupiter API service"
