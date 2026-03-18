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

    // MARK: - Constants

    /// Base transaction fee in lamports (5000 lamports = 0.000005 SOL).
    public static let baseFeeLamports: Int64 = 5000

    /// Approximate transaction fee in SOL for UI display.
    public static let fee: Decimal = Decimal(string: "0.000155")!

    /// Minimum SOL balance required to keep a token account alive (rent-exempt reserve).
    public static let accountRentAmount: Decimal = Decimal(string: "0.001")!

    // MARK: - Public metadata

    /// Base58-encoded Solana public key for this wallet instance.
    public let address: String

    /// `true` when this kit instance targets mainnet-beta.
    public let isMainnet: Bool

    // MARK: - Subsystems (wired in Kit.instance())

    private let connectionManager: ConnectionManager
    private let apiSyncer: ApiSyncer
    private let balanceManager: BalanceManager
    private let tokenAccountManager: TokenAccountManager
    private let transactionManager: TransactionManager
    private let transactionSyncer: TransactionSyncer
    private let syncManager: SyncManager

    // MARK: - Services

    private let rpcApiProvider: IRpcApiProvider
    private let jupiterApiService: JupiterApiService

    // MARK: - Combine subjects (private)

    private let balanceSubject: CurrentValueSubject<Decimal, Never>
    private let syncStateSubject: CurrentValueSubject<SyncState, Never>
    private let lastBlockHeightSubject: CurrentValueSubject<Int64, Never>
    private let tokenBalanceSyncStateSubject: CurrentValueSubject<SyncState, Never>
    private let fungibleTokenAccountsSubject: CurrentValueSubject<[FullTokenAccount], Never>
    private let transactionsSyncStateSubject: CurrentValueSubject<SyncState, Never>
    private let transactionsSubject: PassthroughSubject<[FullTransaction], Never>

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

    /// Emits the current transaction sync state whenever it transitions.
    public var transactionsSyncStatePublisher: AnyPublisher<SyncState, Never> {
        transactionsSyncStateSubject.eraseToAnyPublisher()
    }

    /// Emits newly synced transaction batches.
    public var transactionsPublisher: AnyPublisher<[FullTransaction], Never> {
        transactionsSubject.eraseToAnyPublisher()
    }

    /// Returns a publisher that emits all transactions, optionally filtered by direction.
    ///
    /// When `incoming` is `nil`, all transactions are included.
    /// When set, includes only transactions with a SOL transfer or SPL token transfer
    /// in the given direction. Empty batches are suppressed.
    public func allTransactionsPublisher(incoming: Bool? = nil) -> AnyPublisher<[FullTransaction], Never> {
        transactionManager.allTransactionsPublisher(incoming: incoming)
    }

    /// Returns a publisher that emits only SOL-transfer transactions,
    /// optionally filtered by direction. Empty batches are suppressed.
    public func solTransactionsPublisher(incoming: Bool? = nil) -> AnyPublisher<[FullTransaction], Never> {
        transactionManager.solTransactionsPublisher(incoming: incoming)
    }

    /// Returns a publisher that emits only SPL token transactions for the given mint,
    /// optionally filtered by direction. Empty batches are suppressed.
    public func splTransactionsPublisher(mintAddress: String, incoming: Bool? = nil) -> AnyPublisher<[FullTransaction], Never> {
        transactionManager.splTransactionsPublisher(mintAddress: mintAddress, incoming: incoming)
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

    /// The current transaction sync state. Returns the subject's current value.
    public var transactionsSyncState: SyncState {
        transactionsSyncStateSubject.value
    }

    /// Returns the current list of fungible SPL token accounts.
    public func fungibleTokenAccounts() -> [FullTokenAccount] {
        fungibleTokenAccountsSubject.value
    }

    /// Returns the full token account for the given mint address, or `nil` if not found.
    public func fullTokenAccount(mintAddress: String) -> FullTokenAccount? {
        tokenAccountManager.fullTokenAccount(mintAddress: mintAddress)
    }

    /// Returns a diagnostic snapshot for debugging and support tooling.
    ///
    /// Mirrors Android's `SolanaKit.statusInfo()` and EvmKit's `Kit.statusInfo()`.
    public func statusInfo() -> [(String, Any)] {
        let blockHeight = lastBlockHeightSubject.value
        let blockHeightDisplay: Any = blockHeight > 0 ? blockHeight : "N/A"
        return [
            ("Last Block Height", blockHeightDisplay),
            ("Sync State", syncStateSubject.value.description),
            ("Token Sync State", tokenBalanceSyncStateSubject.value.description),
            ("Transactions Sync State", transactionsSyncStateSubject.value.description),
            ("RPC Source", rpcApiProvider.source),
        ]
    }

    // MARK: - Transaction query methods

    /// Returns all transactions, optionally filtered by direction, paginated from `fromHash`.
    public func transactions(incoming: Bool? = nil, fromHash: String? = nil, limit: Int? = nil) -> [FullTransaction] {
        transactionManager.transactions(incoming: incoming, fromHash: fromHash, limit: limit)
    }

    /// Returns SOL-only transactions, optionally filtered by direction, paginated from `fromHash`.
    public func solTransactions(incoming: Bool? = nil, fromHash: String? = nil, limit: Int? = nil) -> [FullTransaction] {
        transactionManager.solTransactions(incoming: incoming, fromHash: fromHash, limit: limit)
    }

    /// Returns SPL token transactions for the given mint, optionally filtered by direction.
    public func splTransactions(mintAddress: String, incoming: Bool? = nil, fromHash: String? = nil, limit: Int? = nil) -> [FullTransaction] {
        transactionManager.splTransactions(mintAddress: mintAddress, incoming: incoming, fromHash: fromHash, limit: limit)
    }

    // MARK: - Send

    /// Builds, signs, broadcasts, and persists a pending SOL transfer.
    ///
    /// The caller constructs their own `Signer` instance (holding the private key) and passes
    /// it in. `Kit` never owns or stores key material.
    ///
    /// - Parameters:
    ///   - toAddress: Base58-encoded recipient Solana address.
    ///   - amount: Transfer amount in lamports.
    ///   - signer: An Ed25519 `Signer` for the sender's wallet.
    /// - Returns: The pending `FullTransaction` that was broadcast and persisted.
    /// - Throws: `SendError` for invalid addresses or failed broadcasts.
    public func sendSol(toAddress: String, amount: UInt64, signer: Signer) async throws -> FullTransaction {
        try await transactionManager.sendSol(toAddress: toAddress, amount: amount, signer: signer)
    }

    /// Builds, signs, broadcasts, and persists a pending SPL token transfer.
    ///
    /// If the recipient has no Associated Token Account for the given mint, a
    /// `CreateIdempotent` instruction is prepended automatically (matching Android behaviour).
    ///
    /// The caller constructs their own `Signer` instance and passes it in.
    ///
    /// - Parameters:
    ///   - mintAddress: The SPL token mint address.
    ///   - toAddress: Base58-encoded recipient wallet address.
    ///   - amount: Raw (non-UI-adjusted) token amount to transfer.
    ///   - signer: An Ed25519 `Signer` for the sender's wallet.
    /// - Returns: The pending `FullTransaction` that was broadcast and persisted.
    /// - Throws: `SendError` for missing sender token accounts, same-address sends, or
    ///   invalid addresses.
    public func sendSpl(mintAddress: String, toAddress: String, amount: UInt64, signer: Signer) async throws -> FullTransaction {
        try await transactionManager.sendSpl(mintAddress: mintAddress, toAddress: toAddress, amount: amount, signer: signer)
    }

    // MARK: - Init

    private init(
        address: String,
        isMainnet: Bool,
        connectionManager: ConnectionManager,
        apiSyncer: ApiSyncer,
        balanceManager: BalanceManager,
        tokenAccountManager: TokenAccountManager,
        transactionManager: TransactionManager,
        transactionSyncer: TransactionSyncer,
        syncManager: SyncManager,
        rpcApiProvider: IRpcApiProvider,
        jupiterApiService: JupiterApiService,
        balanceSubject: CurrentValueSubject<Decimal, Never>,
        syncStateSubject: CurrentValueSubject<SyncState, Never>,
        lastBlockHeightSubject: CurrentValueSubject<Int64, Never>,
        tokenBalanceSyncStateSubject: CurrentValueSubject<SyncState, Never>,
        fungibleTokenAccountsSubject: CurrentValueSubject<[FullTokenAccount], Never>,
        transactionsSyncStateSubject: CurrentValueSubject<SyncState, Never>,
        transactionsSubject: PassthroughSubject<[FullTransaction], Never>
    ) {
        self.address = address
        self.isMainnet = isMainnet
        self.connectionManager = connectionManager
        self.apiSyncer = apiSyncer
        self.balanceManager = balanceManager
        self.tokenAccountManager = tokenAccountManager
        self.transactionManager = transactionManager
        self.transactionSyncer = transactionSyncer
        self.syncManager = syncManager
        self.rpcApiProvider = rpcApiProvider
        self.jupiterApiService = jupiterApiService
        self.balanceSubject = balanceSubject
        self.syncStateSubject = syncStateSubject
        self.lastBlockHeightSubject = lastBlockHeightSubject
        self.tokenBalanceSyncStateSubject = tokenBalanceSyncStateSubject
        self.fungibleTokenAccountsSubject = fungibleTokenAccountsSubject
        self.transactionsSyncStateSubject = transactionsSyncStateSubject
        self.transactionsSubject = transactionsSubject
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

        let nftClient = NftClient(rpcApiProvider: rpcApiProvider)

        // Each service gets its own NetworkManager instance (standard EvmKit pattern).
        let jupiterApiService = JupiterApiService(networkManager: NetworkManager(logger: nil))

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
            nftClient: nftClient,
            storage: transactionStorage,
            mainStorage: mainStorage
        )

        let transactionManager = TransactionManager(address: address, storage: transactionStorage, rpcApiProvider: rpcApiProvider)

        let pendingTransactionSyncer = PendingTransactionSyncer(
            rpcApiProvider: rpcApiProvider,
            storage: transactionStorage,
            transactionManager: transactionManager
        )

        let transactionSyncer = TransactionSyncer(
            address: address,
            rpcApiProvider: rpcApiProvider,
            nftClient: nftClient,
            storage: transactionStorage,
            transactionManager: transactionManager,
            tokenAccountManager: tokenAccountManager,
            pendingTransactionSyncer: pendingTransactionSyncer
        )

        // Initialise subjects with persisted values so consumers see correct state
        // immediately after Kit.instance() returns, before any RPC response arrives.
        let balanceSubject = CurrentValueSubject<Decimal, Never>(balanceManager.balance ?? 0)
        let syncStateSubject = CurrentValueSubject<SyncState, Never>(.notSynced(error: SyncError.notStarted))
        let lastBlockHeightSubject = CurrentValueSubject<Int64, Never>(apiSyncer.lastBlockHeight ?? 0)
        let tokenBalanceSyncStateSubject = CurrentValueSubject<SyncState, Never>(.notSynced(error: SyncError.notStarted))
        let transactionsSyncStateSubject = CurrentValueSubject<SyncState, Never>(.notSynced(error: SyncError.notStarted))
        let transactionsSubject = PassthroughSubject<[FullTransaction], Never>()

        // Seed fungible token accounts from storage so the value is available immediately.
        let initialFungibleAccounts = tokenAccountManager.tokenAccounts().filter { !$0.mintAccount.isNft }
        let fungibleTokenAccountsSubject = CurrentValueSubject<[FullTokenAccount], Never>(initialFungibleAccounts)

        let syncManager = SyncManager(
            apiSyncer: apiSyncer,
            balanceManager: balanceManager,
            tokenAccountManager: tokenAccountManager,
            transactionSyncer: transactionSyncer,
            transactionManager: transactionManager
        )

        // Wire delegates: ApiSyncer → SyncManager → Kit
        apiSyncer.delegate = syncManager
        balanceManager.delegate = syncManager
        tokenAccountManager.delegate = syncManager
        transactionSyncer.delegate = syncManager

        let kit = Kit(
            address: address,
            isMainnet: rpcSource.isMainnet,
            connectionManager: connectionManager,
            apiSyncer: apiSyncer,
            balanceManager: balanceManager,
            tokenAccountManager: tokenAccountManager,
            transactionManager: transactionManager,
            transactionSyncer: transactionSyncer,
            syncManager: syncManager,
            rpcApiProvider: rpcApiProvider,
            jupiterApiService: jupiterApiService,
            balanceSubject: balanceSubject,
            syncStateSubject: syncStateSubject,
            lastBlockHeightSubject: lastBlockHeightSubject,
            tokenBalanceSyncStateSubject: tokenBalanceSyncStateSubject,
            fungibleTokenAccountsSubject: fungibleTokenAccountsSubject,
            transactionsSyncStateSubject: transactionsSyncStateSubject,
            transactionsSubject: transactionsSubject
        )

        // Post-init: wire SyncManager → Kit (circular reference avoided via weak delegate)
        syncManager.delegate = kit

        return kit
    }

    // MARK: - Static cleanup

    /// Deletes all persisted data (both GRDB databases) for the given wallet identifier.
    ///
    /// Call this when a wallet is removed from the application.
    /// Mirrors Android's `SolanaKit.clear(context, walletId)`.
    public static func clear(walletId: String) throws {
        try MainStorage.clear(walletId: walletId)
        try TransactionStorage.clear(walletId: walletId)
    }

    // MARK: - Lifecycle

    /// Starts all subsystems (network monitoring, sync timers, etc.).
    public func start() {
        connectionManager.start()
        syncManager.start()
    }

    /// Stops all subsystems cleanly.
    public func stop() {
        syncManager.stop()
        connectionManager.stop()
    }

    /// Triggers an immediate sync cycle regardless of the timer interval.
    public func refresh() {
        syncManager.refresh()
    }

    /// Temporarily suspends polling without tearing down the connection monitor.
    public func pause() {
        syncManager.pause()
    }

    /// Resumes polling after a `pause()` call.
    public func resume() {
        syncManager.resume()
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

    func didUpdate(transactionsSyncState: SyncState) {
        DispatchQueue.main.async { [weak self] in
            self?.transactionsSyncStateSubject.send(transactionsSyncState)
        }
    }

    func didUpdate(transactions: [FullTransaction]) {
        DispatchQueue.main.async { [weak self] in
            self?.transactionsSubject.send(transactions)
        }
    }
}

// MARK: - SendError

/// Errors thrown by `Kit.sendSol(_:)` / `Kit.sendSpl(_:)` and their underlying
/// `TransactionManager` implementations.
public enum SendError: Error {
    /// The requested mint has no Associated Token Account in the sender's local storage.
    case tokenAccountNotFound(String)
    /// The derived sender and recipient ATAs are identical — sending to yourself.
    case sameSourceAndDestination
    /// One of the provided addresses could not be decoded as a valid Solana public key.
    case invalidAddress(String)
}
