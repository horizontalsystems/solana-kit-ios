import Foundation
import HsToolKit

/// Fetches, parses, and persists the transaction history for a single wallet address.
final class TransactionSyncer {

    // MARK: - Dependencies

    private let address: String
    private let rpcApiProvider: IRpcApiProvider
    private let nftClient: INftClient
    private let storage: ITransactionStorage
    private let transactionManager: TransactionManager
    private let tokenAccountManager: TokenAccountManager
    private let pendingTransactionSyncer: PendingTransactionSyncer
    private let signatureProvider: ISignatureProvider
    private let logger: Logger?

    // MARK: - Delegate

    /// Receives transaction sync-state change notifications.
    /// Implemented by `SyncManager`, which forwards them to `Kit`.
    weak var delegate: ITransactionSyncerDelegate?

    // MARK: - Sync state

    /// Current sync state of this syncer.
    ///
    /// On every distinct transition the delegate is notified.
    private(set) var syncState: SyncState = .notSynced(error: SyncError.notStarted) {
        didSet {
            guard syncState != oldValue else { return }
            delegate?.didUpdate(transactionsSyncState: syncState)
        }
    }

    // MARK: - Init

    init(
        address: String,
        rpcApiProvider: IRpcApiProvider,
        nftClient: INftClient,
        storage: ITransactionStorage,
        transactionManager: TransactionManager,
        tokenAccountManager: TokenAccountManager,
        pendingTransactionSyncer: PendingTransactionSyncer,
        signatureProvider: ISignatureProvider,
        logger: Logger? = nil
    ) {
        self.address = address
        self.rpcApiProvider = rpcApiProvider
        self.nftClient = nftClient
        self.storage = storage
        self.transactionManager = transactionManager
        self.tokenAccountManager = tokenAccountManager
        self.pendingTransactionSyncer = pendingTransactionSyncer
        self.signatureProvider = signatureProvider
        self.logger = logger
    }

    // MARK: - Stop

    /// Transitions sync state to `.notSynced`. Does not clear cached transactions.
    ///
    /// Called by `SyncManager` when the network becomes unreachable or the kit is stopped.
    func stop(error: Error? = nil) {
        syncState = .notSynced(error: error ?? SyncError.notStarted)
    }

    // MARK: - Main sync entry point

    /// Runs one full incremental sync cycle.
    ///
    /// Pending transactions are polled on every heartbeat regardless of whether
    /// the main history sync is in progress (mirrors Android `TransactionSyncer.sync` line 69).
    func sync() async {
        // Always poll pending transactions first — even if the main sync is already running.
        await pendingTransactionSyncer.sync()

        guard !syncState.syncing else {
            logger?.debug("TransactionSyncer: sync already in progress, skipping")
            return
        }

        logger?.debug("TransactionSyncer: starting sync for \(address)")
        syncState = .syncing(progress: nil)

        do {
            // Step 1: Fetch all new signatures via pluggable provider.
            let signatureInfos = try await signatureProvider.fetchNewSignatures()
            logger?.debug("TransactionSyncer: fetched \(signatureInfos.count) new signature(s)")

            guard !signatureInfos.isEmpty else {
                logger?.debug("TransactionSyncer: no new signatures, sync complete")
                syncState = .synced
                return
            }

            // Step 2: Batch-fetch full transaction responses.
            let signatures = signatureInfos.map { $0.signature }
            logger?.debug("TransactionSyncer: batch-fetching \(signatures.count) transaction(s)")
            let txResponses = try await rpcApiProvider.fetchTransactionsBatch(signatures: signatures)
            logger?.debug("TransactionSyncer: received \(txResponses.count) transaction response(s)")

            // Steps 3-4: Parse each transaction.
            var parsedTransactions: [ParsedTransaction] = []
            var skippedCount = 0
            for signatureInfo in signatureInfos {
                guard let response = txResponses[signatureInfo.signature] else {
                    skippedCount += 1
                    continue
                }
                let parsed = parseTransaction(signature: signatureInfo.signature, response: response)
                parsedTransactions.append(parsed)
            }
            logger?.debug("TransactionSyncer: parsed \(parsedTransactions.count) transaction(s), skipped \(skippedCount) missing response(s)")

            // Step 5-6: Collect placeholder mints from all parsed transactions.
            let allPlaceholders = parsedTransactions.flatMap { $0.mintAccounts }

            // Step 7: Resolve mint metadata for newly seen tokens.
            logger?.debug("TransactionSyncer: resolving \(allPlaceholders.count) placeholder mint(s)")
            let resolvedNewMints = await resolveMintAccounts(placeholderMints: allPlaceholders)
            logger?.debug("TransactionSyncer: resolved \(resolvedNewMints.count) new mint account(s)")
            let resolvedMintMap: [String: MintAccount] = {
                var map: [String: MintAccount] = [:]
                for mint in resolvedNewMints { map[mint.address] = mint }
                return map
            }()

            // Step 8: Replace placeholders with resolved versions in each ParsedTransaction.
            let finalParsed = parsedTransactions.map { parsed in
                ParsedTransaction(
                    transaction: parsed.transaction,
                    tokenTransfers: parsed.tokenTransfers,
                    mintAccounts: parsed.mintAccounts.map { resolvedMintMap[$0.address] ?? $0 },
                    tokenAccounts: parsed.tokenAccounts
                )
            }

            // Step 9: Flatten all records from parsed transactions.
            let allTransactions = finalParsed.map { $0.transaction }
            let allTokenTransfers = finalParsed.flatMap { $0.tokenTransfers }
            let allMintAccounts = resolvedNewMints   // only new mints; existing ones are in DB
            let allTokenAccounts = finalParsed.flatMap { $0.tokenAccounts }

            // Step 10: Persist and emit via TransactionManager.
            logger?.debug("TransactionSyncer: persisting \(allTransactions.count) tx, \(allTokenTransfers.count) token transfers, \(allMintAccounts.count) mints, \(allTokenAccounts.count) token accounts")
            let (discoveredTokenAccounts, existingMintAddresses) = transactionManager.handle(
                transactions: allTransactions,
                tokenTransfers: allTokenTransfers,
                mintAccounts: allMintAccounts,
                tokenAccounts: allTokenAccounts
            )

            // Step 11: Register new token accounts with TokenAccountManager.
            if !discoveredTokenAccounts.isEmpty || !existingMintAddresses.isEmpty {
                logger?.debug("TransactionSyncer: registering \(discoveredTokenAccounts.count) new token account(s), \(existingMintAddresses.count) existing mint(s)")
                await tokenAccountManager.addAccount(
                    receivedTokenAccounts: discoveredTokenAccounts,
                    existingMintAddresses: existingMintAddresses
                )
            }

            // Step 12: Commit provider cursors after successful persist.
            logger?.debug("TransactionSyncer: committing provider cursors")
            try? signatureProvider.commitCursors()

            logger?.debug("TransactionSyncer: sync completed successfully")
            syncState = .synced

        } catch {
            guard !(error is CancellationError) else {
                logger?.debug("TransactionSyncer: sync cancelled")
                return
            }
            logger?.error("TransactionSyncer: sync failed: \(error)")
            syncState = .notSynced(error: error)
        }
    }

    // MARK: - Transaction parsing

    /// Parses a single `RpcTransactionResponse` into a `ParsedTransaction`.
    ///
    /// Mirrors Android `TransactionSyncer.parseTransaction` (lines 195–283).
    private func parseTransaction(signature: String, response: RpcTransactionResponse) -> ParsedTransaction {
        logger?.verbose("TransactionSyncer: parsing tx \(signature)")
        let meta = response.meta
        let blockTime = response.blockTime ?? 0
        let accountKeys = response.transaction?.message?.accountKeys?.map { $0.pubkey } ?? []

        let ourIndex = accountKeys.firstIndex(of: address) ?? -1
        let fee = meta?.fee ?? 0
        let feeString = String(fee)

        // SOL balance change detection.
        var solFrom: String? = nil
        var solTo: String? = nil
        var amountString: String? = nil

        if let meta = meta,
           ourIndex >= 0,
           ourIndex < meta.preBalances.count,
           ourIndex < meta.postBalances.count {
            let balanceChange = meta.postBalances[ourIndex] - meta.preBalances[ourIndex]
            // Fee payer (index 0) pays the fee: add it back to get the net transfer amount.
            let adjustedChange = ourIndex == 0 ? balanceChange + fee : balanceChange

            if adjustedChange != 0 {
                amountString = String(abs(adjustedChange))
                if adjustedChange > 0 {
                    solTo = address
                    solFrom = findCounterparty(
                        preBalances: meta.preBalances,
                        postBalances: meta.postBalances,
                        accountKeys: accountKeys,
                        ourIndex: ourIndex,
                        incoming: true
                    )
                } else {
                    solFrom = address
                    solTo = findCounterparty(
                        preBalances: meta.preBalances,
                        postBalances: meta.postBalances,
                        accountKeys: accountKeys,
                        ourIndex: ourIndex,
                        incoming: false
                    )
                }
            }
        }

        // SPL token transfer parsing.
        var tokenTransfers: [TokenTransfer] = []
        var mintAccounts: [MintAccount] = []
        var tokenAccounts: [TokenAccount] = []

        if let meta = meta {
            // Build lookup maps keyed by "<accountIndex>_<mint>".
            var postByKey: [String: RpcTokenBalance] = [:]
            for balance in meta.postTokenBalances ?? [] {
                postByKey["\(balance.accountIndex)_\(balance.mint)"] = balance
            }
            var preByKey: [String: RpcTokenBalance] = [:]
            for balance in meta.preTokenBalances ?? [] {
                preByKey["\(balance.accountIndex)_\(balance.mint)"] = balance
            }

            let allKeys = Set(postByKey.keys).union(Set(preByKey.keys))

            for key in allKeys {
                let postBalance = postByKey[key]
                let preBalance = preByKey[key]

                // Only process token accounts owned by our address.
                let owner = postBalance?.owner ?? preBalance?.owner
                guard owner == address else { continue }

                guard let mint = postBalance?.mint ?? preBalance?.mint else { continue }

                let decimals = postBalance?.uiTokenAmount?.decimals ?? preBalance?.uiTokenAmount?.decimals ?? 0

                let postAmount = Decimal(string: postBalance?.uiTokenAmount?.amount ?? "0") ?? 0
                let preAmount = Decimal(string: preBalance?.uiTokenAmount?.amount ?? "0") ?? 0
                let change = postAmount - preAmount

                // Skip zero-change entries.
                guard change != 0 else { continue }

                let incoming = change > 0
                let transferAmount = String(describing: abs(change))

                tokenTransfers.append(TokenTransfer(
                    transactionHash: signature,
                    mintAddress: mint,
                    incoming: incoming,
                    amount: transferAmount
                ))

                // Placeholder MintAccount — will be enriched by resolveMintAccounts.
                mintAccounts.append(MintAccount(address: mint, decimals: decimals))

                // TokenAccount for the ATA that held these tokens.
                let accountIndex = postBalance?.accountIndex ?? preBalance?.accountIndex ?? -1
                if accountIndex >= 0 && accountIndex < accountKeys.count {
                    tokenAccounts.append(TokenAccount(
                        address: accountKeys[accountIndex],
                        mintAddress: mint,
                        balance: "0",
                        decimals: decimals
                    ))
                }
            }
        }

        let errorString = meta?.err?.description

        let transaction = Transaction(
            hash: signature,
            timestamp: blockTime,
            fee: feeString,
            from: solFrom,
            to: solTo,
            amount: amountString,
            error: errorString,
            pending: false
        )

        logger?.verbose("TransactionSyncer: tx \(signature) — fee: \(feeString), SOL from: \(solFrom ?? "nil") to: \(solTo ?? "nil"), amount: \(amountString ?? "nil"), tokenTransfers: \(tokenTransfers.count), error: \(errorString ?? "none")")

        return ParsedTransaction(
            transaction: transaction,
            tokenTransfers: tokenTransfers,
            mintAccounts: mintAccounts,
            tokenAccounts: tokenAccounts
        )
    }

    /// Finds the counterparty address for a SOL transfer.
    ///
    /// For incoming transfers, finds the account with the largest balance decrease.
    /// For outgoing transfers, finds the account with the largest balance increase.
    /// Mirrors Android `TransactionSyncer.findCounterparty` (lines 286–308).
    private func findCounterparty(
        preBalances: [Int64],
        postBalances: [Int64],
        accountKeys: [String],
        ourIndex: Int,
        incoming: Bool
    ) -> String? {
        var bestIndex = -1
        var bestChange: Int64 = 0

        for i in accountKeys.indices {
            if i == ourIndex { continue }
            if i >= preBalances.count || i >= postBalances.count { continue }
            let change = postBalances[i] - preBalances[i]
            if incoming && change < bestChange {
                bestChange = change
                bestIndex = i
            } else if !incoming && change > bestChange {
                bestChange = change
                bestIndex = i
            }
        }

        return bestIndex >= 0 ? accountKeys[bestIndex] : nil
    }

    // MARK: - Mint metadata resolution

    /// Resolves placeholder `MintAccount` records for tokens not yet in storage.
    ///
    /// Fetches on-chain SPL Mint layout data plus Metaplex NFT metadata.
    /// Gracefully degrades if the Metaplex fetch fails (NFT detection falls back to
    /// supply == 1 + mintAuthority == nil heuristic).
    ///
    /// Mirrors Android `TransactionSyncer.getMintAccounts` (lines 337–403).
    ///
    /// - Parameter placeholderMints: All placeholder `MintAccount` objects from parsed transactions.
    /// - Returns: Only the NEW (not-yet-stored) mint accounts, resolved or as basic placeholders.
    private func resolveMintAccounts(placeholderMints: [MintAccount]) async -> [MintAccount] {
        // Collect unique addresses from placeholders, filter to those not already in DB.
        let uniqueAddresses = Array(Set(placeholderMints.map { $0.address }))
        let newAddresses = uniqueAddresses.filter { storage.mintAccount(address: $0) == nil }
        logger?.debug("TransactionSyncer: resolveMintAccounts — \(uniqueAddresses.count) unique, \(newAddresses.count) new (not in DB)")

        guard !newAddresses.isEmpty else {
            logger?.debug("TransactionSyncer: all mints already in DB, nothing to resolve")
            return []
        }

        // Fetch raw mint account data from the RPC node.
        let bufferInfos: [BufferInfo?]
        do {
            bufferInfos = try await rpcApiProvider.getMultipleAccounts(addresses: newAddresses)
        } catch {
            logger?.error("TransactionSyncer: getMultipleAccounts failed for mints: \(error)")
            return newAddresses.compactMap { addr in
                placeholderMints.first(where: { $0.address == addr })
            }
        }

        // Fetch Metaplex NFT metadata (graceful degradation — mirrors Android's getOrThrow wrapped in try).
        logger?.debug("TransactionSyncer: fetching Metaplex metadata for \(newAddresses.count) mint(s)")
        let metaplexMap = (try? await nftClient.findAllByMintList(mintAddresses: newAddresses)) ?? [:]
        logger?.debug("TransactionSyncer: Metaplex returned metadata for \(metaplexMap.count) mint(s)")

        var resolvedMints: [MintAccount] = []

        for (index, mintAddress) in newAddresses.enumerated() {
            guard index < bufferInfos.count,
                  let bufferInfo = bufferInfos[index],
                  let layout = try? SplMintLayout(data: bufferInfo.data) else {
                // Fallback: keep placeholder with decimals from parsed token balance.
                if let placeholder = placeholderMints.first(where: { $0.address == mintAddress }) {
                    resolvedMints.append(placeholder)
                }
                continue
            }

            let metadataAccount = metaplexMap[mintAddress]

            // NFT detection logic — mirrors Android and TokenAccountManager.sync().
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

            // Safe Int64 conversion for UInt64 supply.
            let supply: Int64? = layout.supply <= UInt64(Int64.max) ? Int64(layout.supply) : Int64.max

            let mint = MintAccount(
                address: mintAddress,
                decimals: Int(layout.decimals),
                supply: supply,
                isNft: isNft,
                name: metadataAccount?.name,
                symbol: metadataAccount?.symbol,
                uri: metadataAccount?.uri,
                collectionAddress: collectionAddress
            )
            logger?.verbose("TransactionSyncer: resolved mint \(mintAddress) — \(mint.symbol ?? "?") decimals: \(mint.decimals), isNft: \(isNft)")
            resolvedMints.append(mint)
        }

        return resolvedMints
    }
}

// MARK: - ParsedTransaction (private)

/// Intermediate result from parsing a single `RpcTransactionResponse`.
private struct ParsedTransaction {
    var transaction: Transaction
    var tokenTransfers: [TokenTransfer]
    var mintAccounts: [MintAccount]
    var tokenAccounts: [TokenAccount]
}
