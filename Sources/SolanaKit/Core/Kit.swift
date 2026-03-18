import Combine
import Foundation
import HsToolKit

/// Public facade for SolanaKit.
///
/// Instantiate via `Kit.instance(address:rpcSource:walletId:)`.
/// All public state changes are emitted as Combine publishers.
///
/// Lifecycle: `start()` → `stop()` (or `refresh()` / `pause()` / `resume()` for fine-grained control).
public class Kit {

    // MARK: - Subsystems (wired in Kit.instance())

    private let connectionManager: ConnectionManager
    private let apiSyncer: ApiSyncer
    private let balanceManager: BalanceManager
    private let syncManager: SyncManager

    // MARK: - Combine subjects (private)

    private let balanceSubject: CurrentValueSubject<Decimal, Never>
    private let syncStateSubject: CurrentValueSubject<SyncState, Never>
    private let lastBlockHeightSubject: CurrentValueSubject<Int64, Never>

    // MARK: - Public Combine publishers

    /// Emits the current SOL balance (in SOL) whenever it changes.
    public var balancePublisher: AnyPublisher<Decimal, Never> {
        balanceSubject.eraseToAnyPublisher()
    }

    /// Emits the current balance sync state whenever it transitions.
    public var syncStatePublisher: AnyPublisher<SyncState, Never> {
        syncStateSubject.eraseToAnyPublisher()
    }

    /// Emits the latest block height on every polling tick.
    public var lastBlockHeightPublisher: AnyPublisher<Int64, Never> {
        lastBlockHeightSubject.eraseToAnyPublisher()
    }

    // MARK: - Public synchronous accessors

    /// The last known SOL balance (in SOL). Returns the subject's current value.
    public var balance: Decimal {
        balanceSubject.value
    }

    /// The current balance sync state. Returns the subject's current value.
    public var syncState: SyncState {
        syncStateSubject.value
    }

    /// The last known block height. Returns the subject's current value.
    public var lastBlockHeight: Int64 {
        lastBlockHeightSubject.value
    }

    // MARK: - Init

    private init(
        connectionManager: ConnectionManager,
        apiSyncer: ApiSyncer,
        balanceManager: BalanceManager,
        syncManager: SyncManager,
        balanceSubject: CurrentValueSubject<Decimal, Never>,
        syncStateSubject: CurrentValueSubject<SyncState, Never>,
        lastBlockHeightSubject: CurrentValueSubject<Int64, Never>
    ) {
        self.connectionManager = connectionManager
        self.apiSyncer = apiSyncer
        self.balanceManager = balanceManager
        self.syncManager = syncManager
        self.balanceSubject = balanceSubject
        self.syncStateSubject = syncStateSubject
        self.lastBlockHeightSubject = lastBlockHeightSubject
    }

    // MARK: - Factory

    /// Creates a fully-wired `Kit` instance.
    ///
    /// - Parameters:
    ///   - address: Base58-encoded Solana public key for the wallet.
    ///   - rpcSource: RPC endpoint configuration.
    ///   - walletId: Unique identifier used to namespace the GRDB databases on disk.
    public static func instance(address: String, rpcSource: RpcSource, walletId: String) throws -> Kit {
        let connectionManager = ConnectionManager()

        let mainStorage = try MainStorage(walletId: walletId)

        let networkManager = NetworkManager(logger: nil)
        let rpcApiProvider = RpcApiProvider(
            networkManager: networkManager,
            url: rpcSource.url,
            auth: nil
        )

        let apiSyncer = ApiSyncer(
            rpcApiProvider: rpcApiProvider,
            connectionManager: connectionManager,
            storage: mainStorage,
            syncInterval: rpcSource.syncInterval
        )

        // Create BalanceManager first so its init-time storage restore sets `balance`
        // before we seed the subject with that value.
        let balanceManager = BalanceManager(
            address: address,
            rpcApiProvider: rpcApiProvider,
            storage: mainStorage
        )

        // Initialise subjects with persisted values so consumers see correct state
        // immediately after Kit.instance() returns, before any RPC response arrives.
        let balanceSubject = CurrentValueSubject<Decimal, Never>(balanceManager.balance ?? 0)
        let syncStateSubject = CurrentValueSubject<SyncState, Never>(.notSynced(error: SyncError.notStarted))
        let lastBlockHeightSubject = CurrentValueSubject<Int64, Never>(apiSyncer.lastBlockHeight ?? 0)

        let syncManager = SyncManager(
            apiSyncer: apiSyncer,
            balanceManager: balanceManager
        )

        // Wire delegates: ApiSyncer → SyncManager → Kit
        apiSyncer.delegate = syncManager
        balanceManager.delegate = syncManager

        let kit = Kit(
            connectionManager: connectionManager,
            apiSyncer: apiSyncer,
            balanceManager: balanceManager,
            syncManager: syncManager,
            balanceSubject: balanceSubject,
            syncStateSubject: syncStateSubject,
            lastBlockHeightSubject: lastBlockHeightSubject
        )

        // Post-init: wire SyncManager → Kit (circular reference avoided via weak delegate)
        syncManager.delegate = kit

        return kit
    }

    // MARK: - Lifecycle

    /// Starts all subsystems (network monitoring, sync timers, etc.).
    public func start() {
        connectionManager.start()
        apiSyncer.start()
    }

    /// Stops all subsystems cleanly.
    public func stop() {
        apiSyncer.stop()
        connectionManager.stop()
    }

    /// Triggers an immediate sync cycle regardless of the timer interval.
    public func refresh() {
        syncManager.refresh()
    }

    /// Temporarily suspends polling without tearing down the connection monitor.
    public func pause() {
        apiSyncer.pause()
    }

    /// Resumes polling after a `pause()` call.
    public func resume() {
        apiSyncer.resume()
    }
}

// MARK: - ISyncManagerDelegate

extension Kit: ISyncManagerDelegate {

    func didUpdate(balance: Decimal) {
        DispatchQueue.main.async { [weak self] in
            self?.balanceSubject.send(balance)
        }
    }

    func didUpdate(balanceSyncState: SyncState) {
        DispatchQueue.main.async { [weak self] in
            self?.syncStateSubject.send(balanceSyncState)
        }
    }

    func didUpdate(lastBlockHeight: Int64) {
        DispatchQueue.main.async { [weak self] in
            self?.lastBlockHeightSubject.send(lastBlockHeight)
        }
    }
}
