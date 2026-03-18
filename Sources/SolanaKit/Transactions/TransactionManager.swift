import Combine
import Foundation

/// Aggregates parsed transactions, handles pending-to-confirmed merging,
/// persists to storage, and emits Combine events.
///
/// `TransactionManager` is the Combine emission layer for transaction history.
/// It owns the `transactionsSubject` that consumers observe, and implements
/// the merge strategy for pending → confirmed transitions.
///
/// Mirrors Android `TransactionManager.handle()` (lines 67–108).
final class TransactionManager {

    // MARK: - Dependencies

    private let address: String
    private let storage: ITransactionStorage
    private let rpcApiProvider: IRpcApiProvider

    // MARK: - Combine

    private let transactionsSubject = PassthroughSubject<[FullTransaction], Never>()

    /// Publisher that emits a batch of newly-synced or updated transactions.
    var transactionsPublisher: AnyPublisher<[FullTransaction], Never> {
        transactionsSubject.eraseToAnyPublisher()
    }

    // MARK: - Init

    init(address: String, storage: ITransactionStorage, rpcApiProvider: IRpcApiProvider) {
        self.address = address
        self.storage = storage
        self.rpcApiProvider = rpcApiProvider
    }

    // MARK: - Private filter helpers

    /// Returns `true` when the transaction represents a SOL transfer that matches
    /// the optional direction filter.
    ///
    /// Mirrors Android `TransactionManager` lines 115–122.
    private func hasSolTransfer(_ transaction: FullTransaction, incoming: Bool?) -> Bool {
        guard let amount = transaction.transaction.decimalAmount, amount > 0 else {
            return false
        }
        guard let incoming = incoming else {
            return true
        }
        return incoming ? transaction.transaction.to == address : transaction.transaction.from == address
    }

    /// Returns `true` when at least one token transfer matches the given mint address
    /// and optional direction filter.
    ///
    /// Mirrors Android `TransactionManager` lines 124–129.
    private func hasSplTransfer(mintAddress: String, tokenTransfers: [FullTokenTransfer], incoming: Bool?) -> Bool {
        tokenTransfers.contains { fullTransfer in
            guard fullTransfer.mintAccount.address == mintAddress else { return false }
            guard let incoming = incoming else { return true }
            return fullTransfer.tokenTransfer.incoming == incoming
        }
    }

    // MARK: - Filtered publishers

    /// Publisher that emits all transactions, optionally filtered by direction.
    ///
    /// When `incoming` is `nil`, all transactions pass through.
    /// When set, keeps only transactions that have a SOL transfer in the given direction
    /// OR at least one SPL token transfer in the given direction.
    /// Empty batches are suppressed.
    ///
    /// Mirrors Android `_transactionsFlow.map { }.filter { it.isNotEmpty() }`.
    func allTransactionsPublisher(incoming: Bool? = nil) -> AnyPublisher<[FullTransaction], Never> {
        transactionsSubject
            .map { [weak self] transactions -> [FullTransaction] in
                guard let incoming = incoming else {
                    return transactions
                }
                guard let self = self else { return [] }
                return transactions.filter { tx in
                    self.hasSolTransfer(tx, incoming: incoming) ||
                    tx.tokenTransfers.contains { $0.tokenTransfer.incoming == incoming }
                }
            }
            .filter { !$0.isEmpty }
            .eraseToAnyPublisher()
    }

    /// Publisher that emits only transactions containing a SOL transfer, optionally
    /// filtered by direction. Empty batches are suppressed.
    func solTransactionsPublisher(incoming: Bool? = nil) -> AnyPublisher<[FullTransaction], Never> {
        transactionsSubject
            .map { [weak self] transactions -> [FullTransaction] in
                guard let self = self else { return [] }
                return transactions.filter { self.hasSolTransfer($0, incoming: incoming) }
            }
            .filter { !$0.isEmpty }
            .eraseToAnyPublisher()
    }

    /// Publisher that emits only transactions containing an SPL token transfer for
    /// the given mint, optionally filtered by direction. Empty batches are suppressed.
    func splTransactionsPublisher(mintAddress: String, incoming: Bool? = nil) -> AnyPublisher<[FullTransaction], Never> {
        transactionsSubject
            .map { [weak self] transactions -> [FullTransaction] in
                guard let self = self else { return [] }
                return transactions.filter {
                    self.hasSplTransfer(mintAddress: mintAddress, tokenTransfers: $0.tokenTransfers, incoming: incoming)
                }
            }
            .filter { !$0.isEmpty }
            .eraseToAnyPublisher()
    }

    // MARK: - Handle

    /// Merges synced transactions with existing DB records, persists, and emits.
    ///
    /// - Parameters:
    ///   - transactions: Freshly parsed `Transaction` records.
    ///   - tokenTransfers: Freshly parsed `TokenTransfer` records.
    ///   - mintAccounts: Resolved `MintAccount` records for new mints.
    ///   - tokenAccounts: Newly discovered `TokenAccount` records.
    /// - Returns: A tuple of token accounts and existing mint addresses for
    ///   forwarding to `TokenAccountManager.addAccount`.
    @discardableResult
    func handle(
        transactions: [Transaction],
        tokenTransfers: [TokenTransfer],
        mintAccounts: [MintAccount],
        tokenAccounts: [TokenAccount]
    ) -> (tokenAccounts: [TokenAccount], existingMintAddresses: [String]) {
        guard !transactions.isEmpty else {
            return (tokenAccounts, [])
        }

        let hashes = transactions.map { $0.hash }

        // Fetch existing DB records for the same hashes (for pending → confirmed merging).
        let existingFullByHash: [String: FullTransaction] = {
            var map: [String: FullTransaction] = [:]
            for fullTx in storage.fullTransactions(hashes: hashes) {
                map[fullTx.transaction.hash] = fullTx
            }
            return map
        }()

        // Group synced token transfers by transaction hash for quick lookup.
        let syncedTransfersByHash = Dictionary(grouping: tokenTransfers) { $0.transactionHash }

        var mergedTransactions: [Transaction] = []
        var existingMintAddresses: [String] = []

        for tx in transactions {
            if let existing = existingFullByHash[tx.hash] {
                // Merge: prefer synced non-nil from/to/amount, keep existing otherwise.
                // Always mark as confirmed and copy synced error. Mirrors Android lines 80–90.
                let merged = Transaction(
                    hash: tx.hash,
                    timestamp: tx.timestamp,
                    fee: tx.fee,
                    from: tx.from ?? existing.transaction.from,
                    to: tx.to ?? existing.transaction.to,
                    amount: tx.amount ?? existing.transaction.amount,
                    error: tx.error,
                    pending: false,
                    blockHash: existing.transaction.blockHash,
                    lastValidBlockHeight: existing.transaction.lastValidBlockHeight,
                    base64Encoded: existing.transaction.base64Encoded,
                    retryCount: existing.transaction.retryCount
                )
                mergedTransactions.append(merged)

                // If synced has no token transfers but DB has some, collect their mint
                // addresses for re-resolution. Mirrors Android lines 91–97.
                let syncedTransfers = syncedTransfersByHash[tx.hash] ?? []
                if syncedTransfers.isEmpty && !existing.tokenTransfers.isEmpty {
                    existingMintAddresses.append(contentsOf: existing.tokenTransfers.map { $0.mintAccount.address })
                }
            } else {
                mergedTransactions.append(tx)
            }
        }

        // Persist.
        try? storage.save(transactions: mergedTransactions)
        try? storage.save(tokenTransfers: tokenTransfers)
        try? storage.save(mintAccounts: mintAccounts)

        // Re-fetch full records to include joined token transfers / mint accounts.
        let saved = storage.fullTransactions(hashes: hashes)

        DispatchQueue.main.async { [weak self] in
            self?.transactionsSubject.send(saved)
        }

        return (tokenAccounts, existingMintAddresses)
    }

    // MARK: - Notify

    /// Emits a batch of pending-transaction status updates through `transactionsSubject`.
    ///
    /// Called by `PendingTransactionSyncer` after updating pending transactions in storage.
    /// Mirrors Android `TransactionManager.notifyTransactionsUpdate()` (lines 111–113).
    func notifyTransactionsUpdate(_ transactions: [FullTransaction]) {
        DispatchQueue.main.async { [weak self] in
            self?.transactionsSubject.send(transactions)
        }
    }

    // MARK: - Read queries

    func transactions(incoming: Bool?, fromHash: String?, limit: Int?) -> [FullTransaction] {
        storage.transactions(incoming: incoming, fromHash: fromHash, limit: limit)
    }

    func solTransactions(incoming: Bool?, fromHash: String?, limit: Int?) -> [FullTransaction] {
        storage.solTransactions(incoming: incoming, fromHash: fromHash, limit: limit)
    }

    func splTransactions(mintAddress: String, incoming: Bool?, fromHash: String?, limit: Int?) -> [FullTransaction] {
        storage.splTransactions(mintAddress: mintAddress, incoming: incoming, fromHash: fromHash, limit: limit)
    }

    // MARK: - Send SOL

    /// Builds, signs, broadcasts, persists, and emits a pending SOL transfer.
    ///
    /// Steps mirror Android's `TransactionManager.sendSol()`:
    /// 1. Fetch latest blockhash.
    /// 2. Build ComputeBudget + SystemProgram.transfer instructions.
    /// 3. Serialize message → sign → build wire transaction → base64-encode → broadcast.
    /// 4. Persist as a pending `Transaction` and emit via `transactionsSubject`.
    ///
    /// - Parameters:
    ///   - toAddress: Base58-encoded recipient Solana address.
    ///   - amount: Amount in lamports to transfer.
    ///   - signer: The `Signer` that holds the sender's Ed25519 keypair.
    /// - Returns: The pending `FullTransaction` that was persisted.
    /// - Throws: `SendError.invalidAddress` if either address is malformed,
    ///   or any lower-level RPC / serialization error.
    func sendSol(toAddress: String, amount: UInt64, signer: Signer) async throws -> FullTransaction {
        let senderPublicKey = try senderKey()
        guard let recipientPublicKey = try? PublicKey(toAddress) else {
            throw SendError.invalidAddress(toAddress)
        }

        // 1. Fetch recent blockhash.
        let blockhashResponse = try await rpcApiProvider.getLatestBlockhash()

        // 2. Build instructions: priority fees + SOL transfer.
        let instructions: [TransactionInstruction] = priorityFeeInstructions() + [
            SystemProgram.transfer(from: senderPublicKey, to: recipientPublicKey, lamports: amount),
        ]

        // 3–6. Serialize, sign, build wire transaction, broadcast.
        let (base64Tx, txHash) = try await serializeSignAndSend(
            feePayer: senderPublicKey,
            instructions: instructions,
            recentBlockhash: blockhashResponse.blockhash,
            signer: signer
        )

        // 7. Construct a pending Transaction record.
        let transaction = Transaction(
            hash: txHash,
            timestamp: Int64(Date().timeIntervalSince1970),
            fee: "\(Kit.fee)",
            from: address,
            to: toAddress,
            amount: String(amount),
            pending: true,
            blockHash: blockhashResponse.blockhash,
            lastValidBlockHeight: blockhashResponse.lastValidBlockHeight,
            base64Encoded: base64Tx,
            retryCount: 0
        )

        // 8. Persist and emit.
        try? storage.save(transactions: [transaction])
        let fullTx = FullTransaction(transaction: transaction, tokenTransfers: [])
        DispatchQueue.main.async { [weak self] in
            self?.transactionsSubject.send([fullTx])
        }
        return fullTx
    }

    // MARK: - Send SPL

    /// Builds, signs, broadcasts, persists, and emits a pending SPL token transfer.
    ///
    /// Steps mirror Android's `TransactionManager.sendSpl()`:
    /// 1. Look up sender's existing token account from local storage.
    /// 2. Derive recipient's ATA address.
    /// 3. Check whether recipient's ATA exists on-chain.
    /// 4. Fetch latest blockhash.
    /// 5. Build ComputeBudget + (optional CreateIdempotent) + TokenProgram.transfer instructions.
    /// 6. Serialize message → sign → build wire transaction → base64-encode → broadcast.
    /// 7. Persist pending Transaction + TokenTransfer records and emit.
    ///
    /// - Parameters:
    ///   - mintAddress: The SPL token mint address.
    ///   - toAddress: Base58-encoded recipient wallet address.
    ///   - amount: Raw token amount (not UI-adjusted) to transfer.
    ///   - signer: The `Signer` that holds the sender's Ed25519 keypair.
    /// - Returns: The pending `FullTransaction` that was persisted.
    /// - Throws: `SendError.tokenAccountNotFound` if the sender has no token account for the mint,
    ///   `SendError.sameSourceAndDestination` if sender and recipient ATAs are identical,
    ///   `SendError.invalidAddress` if the recipient address is malformed.
    func sendSpl(mintAddress: String, toAddress: String, amount: UInt64, signer: Signer) async throws -> FullTransaction {
        let senderPublicKey = try senderKey()

        guard let recipientPublicKey = try? PublicKey(toAddress) else {
            throw SendError.invalidAddress(toAddress)
        }
        guard let mintPublicKey = try? PublicKey(mintAddress) else {
            throw SendError.invalidAddress(mintAddress)
        }

        // 1. Look up sender's existing token account from local storage.
        guard let senderFullTokenAccount = storage.fullTokenAccount(mintAddress: mintAddress) else {
            throw SendError.tokenAccountNotFound(mintAddress)
        }
        let senderATA = try PublicKey(senderFullTokenAccount.tokenAccount.address)

        // 2. Derive recipient's ATA address.
        let recipientATA = try AssociatedTokenAccountProgram.associatedTokenAddress(
            wallet: recipientPublicKey,
            mint: mintPublicKey
        )

        // Guard: sender and recipient ATAs must differ.
        guard senderATA != recipientATA else {
            throw SendError.sameSourceAndDestination
        }

        // 3. Check whether recipient's ATA exists on-chain.
        let recipientATAAccounts = try await rpcApiProvider.getMultipleAccounts(addresses: [recipientATA.base58])
        // `getMultipleAccounts` returns `[BufferInfo?]`; a non-nil inner element means the account exists.
        let recipientATAExists = recipientATAAccounts.first.flatMap { $0 } != nil

        // 4. Fetch recent blockhash.
        let blockhashResponse = try await rpcApiProvider.getLatestBlockhash()

        // 5. Build instructions.
        var instructions: [TransactionInstruction] = priorityFeeInstructions()
        if !recipientATAExists {
            instructions.append(AssociatedTokenAccountProgram.createIdempotent(
                payer: senderPublicKey,
                associatedToken: recipientATA,
                owner: recipientPublicKey,
                mint: mintPublicKey
            ))
        }
        instructions.append(TokenProgram.transfer(
            source: senderATA,
            destination: recipientATA,
            authority: senderPublicKey,
            amount: amount
        ))

        // 6. Serialize, sign, build wire transaction, broadcast.
        let (base64Tx, txHash) = try await serializeSignAndSend(
            feePayer: senderPublicKey,
            instructions: instructions,
            recentBlockhash: blockhashResponse.blockhash,
            signer: signer
        )

        // 7. Construct pending Transaction + TokenTransfer records.
        let transaction = Transaction(
            hash: txHash,
            timestamp: Int64(Date().timeIntervalSince1970),
            fee: "\(Kit.fee)",
            pending: true,
            blockHash: blockhashResponse.blockhash,
            lastValidBlockHeight: blockhashResponse.lastValidBlockHeight,
            base64Encoded: base64Tx,
            retryCount: 0
        )
        let tokenTransfer = TokenTransfer(
            transactionHash: txHash,
            mintAddress: mintAddress,
            incoming: false,
            amount: String(amount)
        )

        // 8. Persist transaction and token transfer, then emit.
        try? storage.save(transactions: [transaction])
        try? storage.save(tokenTransfers: [tokenTransfer])

        // Assemble FullTokenTransfer for emission (use stored MintAccount if available).
        let mintAccount = storage.mintAccount(address: mintAddress)
            ?? MintAccount(address: mintAddress, decimals: senderFullTokenAccount.tokenAccount.decimals)
        let fullTokenTransfer = FullTokenTransfer(tokenTransfer: tokenTransfer, mintAccount: mintAccount)
        let fullTx = FullTransaction(transaction: transaction, tokenTransfers: [fullTokenTransfer])

        DispatchQueue.main.async { [weak self] in
            self?.transactionsSubject.send([fullTx])
        }
        return fullTx
    }

    // MARK: - Private helpers

    /// Returns the two ComputeBudget priority fee instructions used in every send transaction.
    ///
    /// Hardcoded values match Android's `TransactionManager.priorityFeeInstructions()`:
    /// - 300,000 compute unit limit
    /// - 500,000 micro-lamports per compute unit
    private func priorityFeeInstructions() -> [TransactionInstruction] {
        [
            ComputeBudgetProgram.setComputeUnitLimit(units: 300_000),
            ComputeBudgetProgram.setComputeUnitPrice(microLamports: 500_000),
        ]
    }

    /// Parses the sender's stored address into a `PublicKey`.
    private func senderKey() throws -> PublicKey {
        guard let key = try? PublicKey(address) else {
            throw SendError.invalidAddress(address)
        }
        return key
    }

    /// Serializes the compiled message, signs it, builds the full wire transaction,
    /// base64-encodes it, and broadcasts it via RPC.
    ///
    /// - Returns: A tuple of `(base64EncodedTransaction, txSignature)`.
    private func serializeSignAndSend(
        feePayer: PublicKey,
        instructions: [TransactionInstruction],
        recentBlockhash: String,
        signer: Signer
    ) async throws -> (base64Tx: String, txHash: String) {
        let messageBytes = try SolanaSerializer.serializeMessage(
            feePayer: feePayer,
            instructions: instructions,
            recentBlockhash: recentBlockhash
        )
        let signature = try signer.sign(data: messageBytes)
        let txData = try SolanaSerializer.buildTransaction(
            feePayer: feePayer,
            instructions: instructions,
            recentBlockhash: recentBlockhash,
            signatures: [signature]
        )
        let base64Tx = txData.base64EncodedString()
        let txHash = try await rpcApiProvider.sendTransaction(serializedBase64: base64Tx)
        return (base64Tx, txHash)
    }
}
