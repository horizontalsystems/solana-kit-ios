import Foundation

/// Fetches and persists the native SOL balance for a single wallet address.
///
/// `BalanceManager` is the single source of truth for the SOL balance:
/// - On init it restores the last persisted balance from `IMainStorage`.
/// - On each `sync()` call it fetches a fresh balance via `IRpcApiProvider`,
///   de-duplicates against the cached value, persists on change, and notifies
///   its delegate so `SyncManager` can forward the event to `Kit`.
///
/// Mirrors Android `BalanceManager.kt` exactly, with Kotlin coroutines replaced
/// by Swift `async`/`await` and the listener interface replaced by a typed delegate.
final class BalanceManager {

    // MARK: - Dependencies

    private let address: String
    private let rpcApiProvider: IRpcApiProvider
    private let storage: IMainStorage

    // MARK: - Delegate

    /// Receives balance and sync-state change notifications.
    /// Implemented by `SyncManager`, which forwards them to `Kit`.
    weak var delegate: IBalanceManagerDelegate?

    // MARK: - Cached state

    /// Last known SOL balance (in SOL, not lamports). `nil` until first sync or storage restore.
    private(set) var balance: Decimal?

    /// Current sync state of this manager.
    ///
    /// On every distinct transition the delegate is notified on `DispatchQueue.main`.
    private(set) var syncState: SyncState = .notSynced(error: SyncError.notStarted) {
        didSet {
            guard syncState != oldValue else { return }
            let state = syncState
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didUpdate(balanceSyncState: state)
            }
        }
    }

    // MARK: - Init

    init(
        address: String,
        rpcApiProvider: IRpcApiProvider,
        storage: IMainStorage
    ) {
        self.address = address
        self.rpcApiProvider = rpcApiProvider
        self.storage = storage

        // Restore the last persisted balance so `Kit.balance` has the correct
        // value immediately after `Kit.instance()` returns (mirrors Android BalanceManager line 30).
        if let lamports = storage.balance() {
            self.balance = Decimal(lamports) / 1_000_000_000
        }
    }

    // MARK: - Sync

    /// Fetches the current SOL balance from the RPC endpoint.
    ///
    /// Guards against concurrent in-flight requests (mirrors Android line 39).
    /// Sets sync state to `.syncing` while the request is in flight, then
    /// `.synced` or `.notSynced(error:)` depending on the outcome.
    func sync() async {
        guard !syncState.syncing else { return }

        syncState = .syncing(progress: nil)

        do {
            let lamports = try await rpcApiProvider.getBalance(address: address)
            handleBalance(lamports)
        } catch {
            guard !(error is CancellationError) else { return }
            syncState = .notSynced(error: error)
        }
    }

    // MARK: - Private

    /// Deduplicates, persists, and publishes a new balance value.
    ///
    /// Mirrors Android `BalanceManager.handleBalance` (lines 51-58).
    private func handleBalance(_ lamports: Int64) {
        let newBalance = Decimal(lamports) / 1_000_000_000

        if balance != newBalance {
            balance = newBalance
            try? storage.save(balance: lamports)
            let value = newBalance
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didUpdate(balance: value)
            }
        }

        // Always transition to synced, even when the value was unchanged.
        syncState = .synced
    }

    // MARK: - Stop

    /// Transitions sync state to `.notSynced`. Does not clear the cached balance.
    ///
    /// Called by `SyncManager` when the network becomes unreachable or the kit is stopped.
    func stop(error: Error? = nil) {
        syncState = .notSynced(error: error ?? SyncError.notStarted)
    }
}
