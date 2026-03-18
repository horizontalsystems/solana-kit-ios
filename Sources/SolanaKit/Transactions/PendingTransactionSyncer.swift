import Foundation

/// Monitors unconfirmed (pending) transactions by polling on each block-height heartbeat.
///
/// On each `sync()` call:
/// - Re-fetches each pending transaction to check if it has been confirmed.
/// - Re-broadcasts the original signed transaction if its blockhash is still valid.
/// - Marks the transaction as failed when the blockhash expires.
///
/// Mirrors Android `PendingTransactionSyncer.kt`.
final class PendingTransactionSyncer {

    // MARK: - Dependencies

    private let rpcApiProvider: IRpcApiProvider
    private let storage: ITransactionStorage
    private let transactionManager: TransactionManager

    // MARK: - Init

    init(
        rpcApiProvider: IRpcApiProvider,
        storage: ITransactionStorage,
        transactionManager: TransactionManager
    ) {
        self.rpcApiProvider = rpcApiProvider
        self.storage = storage
        self.transactionManager = transactionManager
    }

    // MARK: - Sync

    /// Polls all pending transactions on each block-height heartbeat.
    ///
    /// For each pending transaction:
    /// - If confirmed on-chain, marks it as non-pending.
    /// - If not yet visible and blockhash still valid, re-broadcasts and increments retry count.
    /// - If not visible and blockhash expired, marks it as failed.
    ///
    /// Individual per-transaction errors are swallowed so one failure does not
    /// prevent processing of remaining pending transactions.
    ///
    /// Mirrors Android `PendingTransactionSyncer.sync()` (lines 24–65).
    func sync() async {
        let pendingTransactions = storage.pendingTransactions()
        guard !pendingTransactions.isEmpty else { return }

        let currentBlockHeight: Int64
        do {
            currentBlockHeight = try await rpcApiProvider.getBlockHeight()
        } catch {
            return
        }

        var updatedTransactions: [Transaction] = []

        for pendingTx in pendingTransactions {
            var confirmedResponse: RpcTransactionResponse? = nil

            do {
                confirmedResponse = try await rpcApiProvider.getTransaction(signature: pendingTx.hash)
            } catch {
                // getTransaction failed — treat same as nil (transaction not yet visible on-chain).
            }

            if let response = confirmedResponse {
                // Transaction is visible on-chain — mark as confirmed.
                updatedTransactions.append(Transaction(
                    hash: pendingTx.hash,
                    timestamp: pendingTx.timestamp,
                    fee: pendingTx.fee,
                    from: pendingTx.from,
                    to: pendingTx.to,
                    amount: pendingTx.amount,
                    error: response.meta?.err?.description,
                    pending: false,
                    blockHash: pendingTx.blockHash,
                    lastValidBlockHeight: pendingTx.lastValidBlockHeight,
                    base64Encoded: pendingTx.base64Encoded,
                    retryCount: pendingTx.retryCount
                ))
            } else if currentBlockHeight <= pendingTx.lastValidBlockHeight {
                // Blockhash still valid — re-broadcast and increment retry count.
                await resendTransaction(base64Encoded: pendingTx.base64Encoded)
                updatedTransactions.append(Transaction(
                    hash: pendingTx.hash,
                    timestamp: pendingTx.timestamp,
                    fee: pendingTx.fee,
                    from: pendingTx.from,
                    to: pendingTx.to,
                    amount: pendingTx.amount,
                    error: pendingTx.error,
                    pending: true,
                    blockHash: pendingTx.blockHash,
                    lastValidBlockHeight: pendingTx.lastValidBlockHeight,
                    base64Encoded: pendingTx.base64Encoded,
                    retryCount: pendingTx.retryCount + 1
                ))
            } else {
                // Blockhash expired — mark as permanently failed.
                updatedTransactions.append(Transaction(
                    hash: pendingTx.hash,
                    timestamp: pendingTx.timestamp,
                    fee: pendingTx.fee,
                    from: pendingTx.from,
                    to: pendingTx.to,
                    amount: pendingTx.amount,
                    error: "BlockHash expired",
                    pending: false,
                    blockHash: pendingTx.blockHash,
                    lastValidBlockHeight: pendingTx.lastValidBlockHeight,
                    base64Encoded: pendingTx.base64Encoded,
                    retryCount: pendingTx.retryCount
                ))
            }
        }

        guard !updatedTransactions.isEmpty else { return }

        try? storage.updateTransactions(updatedTransactions)
        let hashes = updatedTransactions.map { $0.hash }
        let fullTransactions = storage.fullTransactions(hashes: hashes)
        transactionManager.notifyTransactionsUpdate(fullTransactions)
    }

    // MARK: - Resend

    /// Re-broadcasts a pending transaction using the configured RPC endpoint.
    ///
    /// Routes through `IRpcApiProvider.sendTransaction` (the kit's configured RPC source),
    /// rather than hard-coding mainnet as the Android version does.
    /// Errors are silently swallowed — re-broadcast is best-effort.
    ///
    /// Mirrors Android `PendingTransactionSyncer.sendTransaction` (lines 67–99).
    private func resendTransaction(base64Encoded: String) async {
        do {
            _ = try await rpcApiProvider.sendTransaction(serializedBase64: base64Encoded)
        } catch {
            // Silently ignore errors — re-broadcast is best-effort.
        }
    }
}
