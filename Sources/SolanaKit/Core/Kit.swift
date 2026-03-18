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
    private let tokenAccountManager: TokenAccountManager
    private let syncManager: SyncManager

    // MARK: - Combine subjects (private)

    private let balanceSubject: CurrentValueSubject<Decimal, Never>
    private let syncStateSubject: CurrentValueSubject<SyncState, Never>
    private let lastBlockHeightSubject: CurrentValueSubject<Int64, Never>
    private let tokenBalanceSyncStateSubject: CurrentValueSubject<SyncState, Never>
    private let fungibleTokenAccountsSubject: CurrentValueSubject<[FullTokenAccount], Never>

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

    /// Emits the current token balance sync state whenever it transitions.
    public var tokenBalanceSyncStatePublisher: AnyPublisher<SyncState, Never> {
        tokenBalanceSyncStateSubject.eraseToAnyPublisher()
    }

    /// Emits the current list of fungible SPL token accounts whenever it changes.
    public var fungibleTokenAccountsPublisher: AnyPublisher<[FullTokenAccount], Never> {
        fungibleTokenAccountsSubject.eraseToAnyPublisher()
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

    /// The current token balance sync state. Returns the subject's current value.
    public var tokenBalanceSyncState: SyncState {
        tokenBalanceSyncStateSubject.value
    }

    /// Returns the current list of fungible SPL token accounts.
    public func fungibleTokenAccounts() -> [FullTokenAccount] {
        fungibleTokenAccountsSubject.value
    }

    /// Returns the full token account for the given mint address, or `nil` if not found.
    public func fullTokenAccount(mintAddress: String) -> FullTokenAccount? {
        tokenAccountManager.fullTokenAccount(mintAddress: mintAddress)
    }

    // MARK: - Init

    private init(
        connectionManager: ConnectionManager,
        apiSyncer: ApiSyncer,
        balanceManager: BalanceManager,
        tokenAccountManager: TokenAccountManager,
        syncManager: SyncManager,
        balanceSubject: CurrentValueSubject<Decimal, Never>,
        syncStateSubject: CurrentValueSubject<SyncState, Never>,
        lastBlockHeightSubject: CurrentValueSubject<Int64, Never>,
        tokenBalanceSyncStateSubject: CurrentValueSubject<SyncState, Never>,
        fungibleTokenAccountsSubject: CurrentValueSubject<[FullTokenAccount], Never>
    ) {
        self.connectionManager = connectionManager
        self.apiSyncer = apiSyncer
        self.balanceManager = balanceManager
        self.tokenAccountManager = tokenAccountManager
        self.syncManager = syncManager
        self.balanceSubject = balanceSubject
        self.syncStateSubject = syncStateSubject
        self.lastBlockHeightSubject = lastBlockHeightSubject
        self.tokenBalanceSyncStateSubject = tokenBalanceSyncStateSubject
        self.fungibleTokenAccountsSubject = fungibleTokenAccountsSubject
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
        let transactionStorage = try TransactionStorage(walletId: walletId, address: address)

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

        let tokenAccountManager = TokenAccountManager(
            address: address,
            rpcApiProvider: rpcApiProvider,
            storage: transactionStorage,
            mainStorage: mainStorage
        )

        // Initialise subjects with persisted values so consumers see correct state
        // immediately after Kit.instance() returns, before any RPC response arrives.
        let balanceSubject = CurrentValueSubject<Decimal, Never>(balanceManager.balance ?? 0)
        let syncStateSubject = CurrentValueSubject<SyncState, Never>(.notSynced(error: SyncError.notStarted))
        let lastBlockHeightSubject = CurrentValueSubject<Int64, Never>(apiSyncer.lastBlockHeight ?? 0)
        let tokenBalanceSyncStateSubject = CurrentValueSubject<SyncState, Never>(.notSynced(error: SyncError.notStarted))

        // Seed fungible token accounts from storage so the value is available immediately.
        let initialFungibleAccounts = tokenAccountManager.tokenAccounts().filter { !$0.mintAccount.isNft }
        let fungibleTokenAccountsSubject = CurrentValueSubject<[FullTokenAccount], Never>(initialFungibleAccounts)

        let syncManager = SyncManager(
            apiSyncer: apiSyncer,
            balanceManager: balanceManager,
            tokenAccountManager: tokenAccountManager
        )

        // Wire delegates: ApiSyncer → SyncManager → Kit
        apiSyncer.delegate = syncManager
        balanceManager.delegate = syncManager
        tokenAccountManager.delegate = syncManager

        let kit = Kit(
            connectionManager: connectionManager,
            apiSyncer: apiSyncer,
            balanceManager: balanceManager,
            tokenAccountManager: tokenAccountManager,
            syncManager: syncManager,
            balanceSubject: balanceSubject,
            syncStateSubject: syncStateSubject,
            lastBlockHeightSubject: lastBlockHeightSubject,
            tokenBalanceSyncStateSubject: tokenBalanceSyncStateSubject,
            fungibleTokenAccountsSubject: fungibleTokenAccountsSubject
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

    func didUpdate(tokenAccounts: [FullTokenAccount]) {
        DispatchQueue.main.async { [weak self] in
            self?.fungibleTokenAccountsSubject.send(tokenAccounts)
        }
    }

    func didUpdate(tokenBalanceSyncState: SyncState) {
        DispatchQueue.main.async { [weak self] in
            self?.tokenBalanceSyncStateSubject.send(tokenBalanceSyncState)
        }
    }
}
