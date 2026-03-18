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

    // TODO: [milestone 3.1] let syncManager: SyncManager
    // TODO: [milestone 3.1] let balanceManager: BalanceManager
    // TODO: [milestone 3.1] let tokenAccountManager: TokenAccountManager
    // TODO: [milestone 3.1] let transactionManager: TransactionManager

    // MARK: - Init

    private init(connectionManager: ConnectionManager, apiSyncer: ApiSyncer) {
        self.connectionManager = connectionManager
        self.apiSyncer = apiSyncer
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

        // TODO: [milestone 3.1] Set apiSyncer.delegate = syncManager once SyncManager is wired.
        // Until then the timer runs and persists block height to storage,
        // but no downstream sync is triggered.

        // TODO: [milestone 3.1] Wire remaining subsystems here.

        return Kit(connectionManager: connectionManager, apiSyncer: apiSyncer)
    }

    // MARK: - Lifecycle

    /// Starts all subsystems (network monitoring, sync timers, etc.).
    public func start() {
        connectionManager.start()
        apiSyncer.start()
        // TODO: [milestone 3.1] syncManager.start()
    }

    /// Stops all subsystems cleanly.
    public func stop() {
        apiSyncer.stop()
        connectionManager.stop()
        // TODO: [milestone 3.1] syncManager.stop()
    }

    /// Triggers an immediate sync cycle regardless of the timer interval.
    public func refresh() {
        // TODO: [milestone 3.1] syncManager.refresh()
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
