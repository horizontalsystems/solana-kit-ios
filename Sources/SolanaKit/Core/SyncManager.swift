import Combine
import Foundation

/// Orchestrates all sync subsystems by wiring `ApiSyncer` heartbeats to downstream managers.
///
/// `SyncManager` sits between the polling layer (`ApiSyncer`) and the business-logic
/// managers (`BalanceManager`, `TokenAccountManager`, `TransactionSyncer`). It:
/// - Reacts to `IApiSyncerDelegate` callbacks (block height ticks, syncer state changes).
/// - Reacts to `IBalanceManagerDelegate` callbacks (balance change, sync state change).
/// - Reacts to `ITokenAccountManagerDelegate` callbacks (token accounts, sync state change).
/// - Reacts to `ITransactionSyncerDelegate` callbacks (transaction sync state change).
/// - Forwards all events to `Kit` via `ISyncManagerDelegate`.
///
/// Mirrors Android `SyncManager.kt`, with coroutines replaced by `Task { }` and
/// listener interfaces replaced by the delegate pattern.
class SyncManager {

    // MARK: - Dependencies

    private let apiSyncer: ApiSyncer
    private let balanceManager: BalanceManager
    private let tokenAccountManager: TokenAccountManager

    // MARK: - Optional subsystems (wired in Kit.instance() — set after init)

    /// Transaction syncer — injected after init by `Kit.instance()`.
    var transactionSyncer: TransactionSyncer?

    /// Transaction manager — injected after init by `Kit.instance()`.
    var transactionManager: TransactionManager? {
        didSet {
            guard let tm = transactionManager else { return }
            // When new transactions arrive:
            // 1. Refresh the SOL balance (mirrors Android cross-cutting subscription).
            // 2. Forward the batch to Kit via the sync manager delegate.
            transactionManagerCancellable = tm.transactionsPublisher
                .sink { [weak self] transactions in
                    Task { [weak self] in
                        await self?.balanceManager.sync()
                    }
                    self?.delegate?.didUpdate(transactions: transactions)
                }
        }
    }

    // MARK: - Delegate (weak — Kit holds SyncManager, not the other way around)

    weak var delegate: ISyncManagerDelegate?

    // MARK: - Private state

    private var transactionManagerCancellable: AnyCancellable?

    // MARK: - Convenience computed accessors

    /// Current balance sync state, read directly from `BalanceManager`.
    var balanceSyncState: SyncState {
        balanceManager.syncState
    }

    /// Current token balance sync state, read directly from `TokenAccountManager`.
    var tokenBalanceSyncState: SyncState {
        tokenAccountManager.syncState
    }

    /// Current transaction sync state, read directly from `TransactionSyncer`.
    var transactionsSyncState: SyncState {
        transactionSyncer?.syncState ?? .notSynced(error: SyncError.notStarted)
    }

    // MARK: - Init

    init(apiSyncer: ApiSyncer, balanceManager: BalanceManager, tokenAccountManager: TokenAccountManager) {
        self.apiSyncer = apiSyncer
        self.balanceManager = balanceManager
        self.tokenAccountManager = tokenAccountManager
    }

    // MARK: - Refresh

    /// Triggers an immediate sync cycle.
    ///
    /// If the API syncer is not in a ready state (e.g. lost connection), the syncer
    /// is restarted so it can re-establish a polling loop once the network returns.
    /// Otherwise a direct balance + token account + transaction sync is triggered, matching
    /// Android `SyncManager.refresh` (lines 64-73).
    func refresh() {
        if case .ready = apiSyncer.state {
            Task { [weak self] in
                await self?.balanceManager.sync()
                await self?.tokenAccountManager.sync()
                await self?.transactionSyncer?.sync()
            }
        } else {
            apiSyncer.stop()
            apiSyncer.start()
        }
    }
}

// MARK: - IApiSyncerDelegate

extension SyncManager: IApiSyncerDelegate {

    /// Reacts to `ApiSyncer` readiness transitions.
    ///
    /// When the syncer becomes not-ready (network loss, RPC error), downstream
    /// managers are stopped with the originating error so consumers see
    /// `.notSynced(error:)` instead of a stale `.synced` state.
    /// Mirrors Android `SyncManager.didUpdateApiState` (lines 92-103).
    func didUpdateSyncerState(_ state: SyncerState) {
        switch state {
        case .ready:
            // Sync is triggered by block height ticks, not state changes.
            break
        case .preparing:
            break
        case .notReady(let error):
            balanceManager.stop(error: error)
            tokenAccountManager.stop(error: error)
            transactionSyncer?.stop(error: error)
        }
    }

    /// Receives every block height tick and triggers a full sync cycle.
    ///
    /// This is the primary heartbeat that drives all downstream data fetches.
    /// Mirrors Android `SyncManager.didUpdateLastBlockHeight` (lines 123-130).
    func didUpdateLastBlockHeight(_ lastBlockHeight: Int64) {
        delegate?.didUpdate(lastBlockHeight: lastBlockHeight)
        Task { [weak self] in
            await self?.balanceManager.sync()
            await self?.tokenAccountManager.sync()
            await self?.transactionSyncer?.sync()
        }
    }
}

// MARK: - IBalanceManagerDelegate

extension SyncManager: IBalanceManagerDelegate {

    func didUpdate(balance: Decimal) {
        delegate?.didUpdate(balance: balance)
    }

    func didUpdate(balanceSyncState: SyncState) {
        delegate?.didUpdate(balanceSyncState: balanceSyncState)
    }
}

// MARK: - ITokenAccountManagerDelegate

extension SyncManager: ITokenAccountManagerDelegate {

    func didUpdate(tokenAccounts: [FullTokenAccount]) {
        delegate?.didUpdate(tokenAccounts: tokenAccounts)
    }

    func didUpdate(tokenBalanceSyncState: SyncState) {
        delegate?.didUpdate(tokenBalanceSyncState: tokenBalanceSyncState)
    }
}

// MARK: - ITransactionSyncerDelegate

extension SyncManager: ITransactionSyncerDelegate {

    /// Forwards transaction sync state changes to `Kit` via `ISyncManagerDelegate`.
    func didUpdate(transactionsSyncState: SyncState) {
        delegate?.didUpdate(transactionsSyncState: transactionsSyncState)
    }
}
