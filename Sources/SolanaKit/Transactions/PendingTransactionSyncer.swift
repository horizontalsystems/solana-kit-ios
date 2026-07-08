import Foundation
import HsToolKit

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
    private let logger: Logger?

    // MARK: - Init

    init(
        rpcApiProvider: IRpcApiProvider,
        storage: ITransactionStorage,
        transactionManager: TransactionManager,
        logger: Logger? = nil
    ) {
        self.rpcApiProvider = rpcApiProvider
        self.storage = storage
        self.transactionManager = transactionManager
        self.logger = logger
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
            } catch {}

            // Mutate the fetched record (Transaction is a class) instead of reconstructing it
            // field-by-field — columns not named below keep their stored values automatically,
            // so a new column (like programIds once was) can't be silently dropped here.
            if let response = confirmedResponse {
                pendingTx.error = response.meta?.err?.description
                pendingTx.pending = false
            } else if currentBlockHeight <= pendingTx.lastValidBlockHeight {
                await resendTransaction(base64Encoded: pendingTx.base64Encoded)
                pendingTx.retryCount += 1
            } else {
                pendingTx.error = "BlockHash expired"
                pendingTx.pending = false
            }
            updatedTransactions.append(pendingTx)
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
