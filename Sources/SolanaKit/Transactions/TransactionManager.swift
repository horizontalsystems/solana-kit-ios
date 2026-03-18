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

    // MARK: - Combine

    private let transactionsSubject = PassthroughSubject<[FullTransaction], Never>()

    /// Publisher that emits a batch of newly-synced or updated transactions.
    var transactionsPublisher: AnyPublisher<[FullTransaction], Never> {
        transactionsSubject.eraseToAnyPublisher()
    }

    // MARK: - Init

    init(address: String, storage: ITransactionStorage) {
        self.address = address
        self.storage = storage
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
}
