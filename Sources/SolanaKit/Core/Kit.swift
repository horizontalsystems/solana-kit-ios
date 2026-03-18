import Combine
import Foundation

/// Public facade for SolanaKit.
///
/// Instantiate via `Kit.instance(address:rpcSource:walletId:)`.
/// All public state changes are emitted as Combine publishers.
///
/// Lifecycle: `start()` → `stop()` (or `refresh()` / `pause()` / `resume()` for fine-grained control).
public class Kit {

    // MARK: - Subsystems (wired in Kit.instance())

    private let connectionManager: ConnectionManager

    // TODO: [milestone 2.4] let apiSyncer: ApiSyncer
    // TODO: [milestone 3.1] let syncManager: SyncManager
    // TODO: [milestone 3.1] let balanceManager: BalanceManager
    // TODO: [milestone 3.1] let tokenAccountManager: TokenAccountManager
    // TODO: [milestone 3.1] let transactionManager: TransactionManager

    // MARK: - Init

    private init(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager
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

        // TODO: [milestone 2.4]
        // let apiSyncer = ApiSyncer(rpcApiProvider: rpcApiProvider,
        //                            connectionManager: connectionManager,
        //                            syncInterval: 30)

        // TODO: [milestone 3.1] Wire remaining subsystems here.

        return Kit(connectionManager: connectionManager)
    }

    // MARK: - Lifecycle

    /// Starts all subsystems (network monitoring, sync timers, etc.).
    public func start() {
        connectionManager.start()
        // TODO: [milestone 3.1] syncManager.start()
    }

    /// Stops all subsystems cleanly.
    public func stop() {
        connectionManager.stop()
        // TODO: [milestone 3.1] syncManager.stop()
    }

    /// Triggers an immediate sync cycle regardless of the timer interval.
    public func refresh() {
        // TODO: [milestone 3.1] syncManager.refresh()
    }
}
