import Foundation

/// Fetches, parses, and persists SPL token accounts for a single wallet address.
///
/// `TokenAccountManager` is the single source of truth for the wallet's SPL token account list:
/// - On each `sync()` call it fetches all on-chain token accounts via `getTokenAccountsByOwner`,
///   discovers new mint accounts via `getMultipleAccounts`, persists both, and notifies its
///   delegate so `SyncManager` can forward the event to `Kit`.
///
/// Mirrors Android `TokenAccountManager.kt` with Kotlin coroutines replaced by Swift
/// `async`/`await` and the listener interface replaced by a typed delegate.
final class TokenAccountManager {

    // MARK: - Dependencies

    private let address: String
    private let rpcApiProvider: IRpcApiProvider
    private let nftClient: INftClient
    private let storage: ITransactionStorage
    private let mainStorage: IMainStorage

    // MARK: - Delegate

    /// Receives token account and sync-state change notifications.
    /// Implemented by `SyncManager`, which forwards them to `Kit`.
    weak var delegate: ITokenAccountManagerDelegate?

    // MARK: - Sync state

    /// Current sync state of this manager.
    ///
    /// On every distinct transition the delegate is notified on `DispatchQueue.main`.
    private(set) var syncState: SyncState = .notSynced(error: SyncError.notStarted) {
        didSet {
            guard syncState != oldValue else { return }
            let state = syncState
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didUpdate(tokenBalanceSyncState: state)
            }
        }
    }

    // MARK: - Init

    init(
        address: String,
        rpcApiProvider: IRpcApiProvider,
        nftClient: INftClient,
        storage: ITransactionStorage,
        mainStorage: IMainStorage
    ) {
        self.address = address
        self.rpcApiProvider = rpcApiProvider
        self.nftClient = nftClient
        self.storage = storage
        self.mainStorage = mainStorage
    }

    // MARK: - Sync

    /// Fetches all SPL token accounts from the RPC endpoint.
    ///
    /// Guards against concurrent in-flight requests (mirrors Android `TokenAccountManager` guard).
    /// Sets sync state to `.syncing` while the request is in flight, then `.synced` or
    /// `.notSynced(error:)` depending on the outcome.
    func sync() async {
        guard !syncState.syncing else { return }

        syncState = .syncing(progress: nil)

        do {
            // 1. Fetch all on-chain SPL token accounts for this address.
            let rpcKeyedAccounts = try await rpcApiProvider.getTokenAccountsByOwner(address: address)

            // 2. Convert each RPC result to a TokenAccount record.
            let tokenAccounts = rpcKeyedAccounts.map { rpcAccount -> TokenAccount in
                let info = rpcAccount.account.data.parsed.info
                return TokenAccount(
                    address: rpcAccount.pubkey,
                    mintAddress: info.mint,
                    balance: info.tokenAmount.amount,
                    decimals: info.tokenAmount.decimals
                )
            }

            // 3. Collect mint addresses for mints not already stored.
            let uniqueMintAddresses = Set(tokenAccounts.map { $0.mintAddress })
            let newMintAddresses = uniqueMintAddresses.filter { storage.mintAccount(address: $0) == nil }

            // 4. Fetch mint account data for new mints and parse.
            var mintAccounts: [MintAccount] = []
            if !newMintAddresses.isEmpty {
                let sortedNewMints = Array(newMintAddresses).sorted()
                let bufferInfos = try await rpcApiProvider.getMultipleAccounts(addresses: sortedNewMints)

                // 4a. Fetch Metaplex on-chain metadata for the same mints.
                let metaplexMap = (try? await nftClient.findAllByMintList(mintAddresses: sortedNewMints)) ?? [:]

                for (index, mintAddress) in sortedNewMints.enumerated() {
                    guard index < bufferInfos.count, let bufferInfo = bufferInfos[index] else { continue }
                    guard let layout = try? SplMintLayout(data: bufferInfo.data) else { continue }

                    let metadataAccount = metaplexMap[mintAddress]

                    // Full NFT detection logic matching Android's TransactionSyncer.getMintAccounts().
                    // `.programmableNonFungible` (pNFT, Metaplex v1.3+) is also treated as an NFT.
                    let isNft: Bool
                    if layout.decimals != 0 {
                        isNft = false
                    } else if layout.supply == 1 && layout.mintAuthority == nil {
                        isNft = true
                    } else if metadataAccount?.tokenStandard == .nonFungible {
                        isNft = true
                    } else if metadataAccount?.tokenStandard == .fungibleAsset {
                        isNft = true
                    } else if metadataAccount?.tokenStandard == .nonFungibleEdition {
                        isNft = true
                    } else if metadataAccount?.tokenStandard == .programmableNonFungible {
                        isNft = true
                    } else {
                        isNft = false
                    }

                    // Verified collection address (nil if unverified or absent).
                    let collectionAddress: String? = metadataAccount?.collection.flatMap { col in
                        col.verified ? col.key : nil
                    }

                    let mintAccount = MintAccount(
                        address: mintAddress,
                        decimals: Int(layout.decimals),
                        supply: layout.supply <= Int64.max ? Int64(layout.supply) : Int64.max,
                        isNft: isNft,
                        name: metadataAccount?.name,
                        symbol: metadataAccount?.symbol,
                        uri: metadataAccount?.uri,
                        collectionAddress: collectionAddress
                    )
                    mintAccounts.append(mintAccount)
                }
            }

            // 5. Persist token and mint accounts.
            try? storage.save(tokenAccounts: tokenAccounts)
            try? storage.save(mintAccounts: mintAccounts)

            // 6. Read the full joined list; filter to fungible (non-NFT) accounts.
            let allFull = storage.fullTokenAccounts()
            let fungibleAccounts = allFull.filter { !$0.mintAccount.isNft }

            // 7. Notify delegate.
            let accounts = fungibleAccounts
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didUpdate(tokenAccounts: accounts)
            }

            // 8. Mark initial sync complete (idempotent).
            if !mainStorage.initialSynced() {
                try? mainStorage.setInitialSynced()
            }

            syncState = .synced

        } catch {
            guard !(error is CancellationError) else { return }
            syncState = .notSynced(error: error)
        }
    }

    // MARK: - Integration helpers

    /// Called by `TransactionSyncer` when new token accounts are discovered during
    /// transaction parsing. Saves the new accounts then triggers a full sync.
    func addAccount(receivedTokenAccounts: [TokenAccount], existingMintAddresses _: [String]) async {
        try? storage.save(tokenAccounts: receivedTokenAccounts)
        await sync()
    }

    /// Pre-registers a token account for send-SPL before the transaction is broadcast.
    ///
    /// The ATA address must be pre-computed by the caller; PDA derivation will be added
    /// in milestone 4.4. Checks for an existing account first to avoid duplicate entries.
    func addTokenAccount(ataAddress: String, mintAddress: String, decimals: Int) {
        guard !storage.tokenAccountExists(mintAddress: mintAddress) else { return }

        let tokenAccount = TokenAccount(
            address: ataAddress,
            mintAddress: mintAddress,
            balance: "0",
            decimals: decimals
        )
        let mintAccount = MintAccount(
            address: mintAddress,
            decimals: decimals
        )

        try? storage.addTokenAccount(tokenAccount)
        try? storage.addMintAccount(mintAccount)
    }

    // MARK: - Synchronous reads

    /// Returns the full token account for the given mint address, or `nil` if not found.
    func fullTokenAccount(mintAddress: String) -> FullTokenAccount? {
        storage.fullTokenAccount(mintAddress: mintAddress)
    }

    /// Returns all full token accounts currently in storage.
    func tokenAccounts() -> [FullTokenAccount] {
        storage.fullTokenAccounts()
    }

    // MARK: - Stop

    /// Transitions sync state to `.notSynced`. Does not clear cached token accounts.
    ///
    /// Called by `SyncManager` when the network becomes unreachable or the kit is stopped.
    func stop(error: Error? = nil) {
        syncState = .notSynced(error: error ?? SyncError.notStarted)
    }
}
