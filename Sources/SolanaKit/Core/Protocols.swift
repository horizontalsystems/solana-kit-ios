/// Internal protocol definitions for SolanaKit.
///
/// Every infrastructure type is accessed through a protocol so that
/// managers can be unit-tested with mock implementations.

// MARK: - Connection / reachability protocol

import Combine

protocol IConnectionManager {
    /// Current network reachability state.
    var isConnected: Bool { get }

    /// Publisher that emits the new value whenever reachability changes.
    /// Only fires on distinct state transitions (connected → disconnected and vice-versa).
    var isConnectedPublisher: AnyPublisher<Bool, Never> { get }

    func start()
    func stop()
}

// MARK: - RPC provider protocol

protocol IRpcApiProvider {
    var source: String { get }
    func fetch<T>(rpc: JsonRpc<T>) async throws -> T
    func fetchBatch<T>(rpcs: [JsonRpc<T>]) async throws -> [T?]
    func fetchTransactionsBatch(signatures: [String]) async throws -> [String: RpcTransactionResponse]
}

// MARK: - Storage protocols

protocol ITransactionStorage {
    // MARK: Transaction CRUD
    func save(transactions: [Transaction]) throws
    func transaction(hash: String) -> Transaction?
    func pendingTransactions() -> [Transaction]
    func lastNonPendingTransaction() -> Transaction?
    func updateTransactions(_ transactions: [Transaction]) throws

    // MARK: TokenTransfer
    func save(tokenTransfers: [TokenTransfer]) throws

    // MARK: MintAccount
    func save(mintAccounts: [MintAccount]) throws
    func mintAccount(address: String) -> MintAccount?
    func addMintAccount(_ mintAccount: MintAccount) throws

    // MARK: TokenAccount
    func save(tokenAccounts: [TokenAccount]) throws
    func tokenAccount(mintAddress: String) -> TokenAccount?
    func allTokenAccounts() -> [TokenAccount]
    func tokenAccounts(mintAddresses: [String]) -> [TokenAccount]
    func tokenAccountExists(mintAddress: String) -> Bool
    func addTokenAccount(_ tokenAccount: TokenAccount) throws
    func fullTokenAccount(mintAddress: String) -> FullTokenAccount?
    func fullTokenAccounts() -> [FullTokenAccount]

    // MARK: Syncer state
    func lastSyncedTransaction(syncSourceName: String) -> LastSyncedTransaction?
    func save(lastSyncedTransaction: LastSyncedTransaction) throws

    // MARK: Complex queries
    func transactions(incoming: Bool?, fromHash: String?, limit: Int?) -> [FullTransaction]
    func solTransactions(incoming: Bool?, fromHash: String?, limit: Int?) -> [FullTransaction]
    func splTransactions(mintAddress: String, incoming: Bool?, fromHash: String?, limit: Int?) -> [FullTransaction]
    func fullTransactions(hashes: [String]) -> [FullTransaction]
}

protocol IMainStorage {
    /// Returns the cached SOL balance in lamports, or `nil` if not yet persisted.
    func balance() -> Int64?

    /// Persists the SOL balance in lamports.
    func save(balance: Int64) throws

    /// Returns the last known block height (slot), or `nil` if not yet persisted.
    func lastBlockHeight() -> Int64?

    /// Persists the last known block height (slot).
    func save(lastBlockHeight: Int64) throws

    /// Returns `true` after the initial full transaction history fetch has completed.
    func initialSynced() -> Bool

    /// Marks initial sync as complete. Idempotent — safe to call multiple times.
    func setInitialSynced() throws
}

// MARK: - ApiSyncer state & delegate

/// Internal readiness state of the `ApiSyncer` (the API-layer timer loop).
///
/// Separate from the public `SyncState` — `SyncerState` reflects whether the poller
/// itself can run, not the progress of any individual data-fetch subsystem.
/// Mirrors EvmKit's `SyncerState` (see `ApiProtocols.swift`) and Android's
/// `ApiSyncer.SyncerState` sealed class.
enum SyncerState {
    /// Awaiting the first reachability signal before starting the timer.
    case preparing
    /// Network is reachable; the polling timer is running.
    case ready
    /// Polling is not possible — e.g. no network connection or kit not started.
    case notReady(error: Error)
}

extension SyncerState: Equatable {
    static func == (lhs: SyncerState, rhs: SyncerState) -> Bool {
        switch (lhs, rhs) {
        case (.preparing, .preparing): return true
        case (.ready, .ready): return true
        case let (.notReady(lhsError), .notReady(rhsError)):
            return "\(lhsError)" == "\(rhsError)"
        default: return false
        }
    }
}

/// Delegate notified by `ApiSyncer` on state transitions and new block heights.
///
/// Implemented by `SyncManager` (milestone 3.1) which fans out sync work to
/// `BalanceManager`, `TokenAccountManager`, and `TransactionSyncer`.
protocol IApiSyncerDelegate: AnyObject {
    /// Called when the syncer's readiness state changes (on distinct transitions only).
    func didUpdateSyncerState(_ state: SyncerState)

    /// Called on every poll tick with the latest block height (slot).
    /// Fires even when the value is unchanged — this is the heartbeat that drives
    /// downstream sync subsystems.
    func didUpdateLastBlockHeight(_ lastBlockHeight: Int64)
}

// MARK: - IRpcApiProvider typed convenience API

/// Default implementations wrapping `fetch(rpc:)` with typed `JsonRpc` subclasses.
///
/// Managers call these methods directly; no manager needs to know about `JsonRpc` internals.
extension IRpcApiProvider {
    func getBalance(address: String) async throws -> Int64 {
        try await fetch(rpc: GetBalanceJsonRpc(address: address))
    }

    func getBlockHeight() async throws -> Int64 {
        try await fetch(rpc: GetBlockHeightJsonRpc())
    }

    func getTokenAccountsByOwner(address: String) async throws -> [RpcKeyedAccount] {
        try await fetch(rpc: GetTokenAccountsByOwnerJsonRpc(ownerAddress: address))
    }

    func getSignaturesForAddress(
        address: String,
        limit: Int? = nil,
        before: String? = nil,
        until: String? = nil
    ) async throws -> [SignatureInfo] {
        try await fetch(rpc: GetSignaturesForAddressJsonRpc(
            address: address,
            limit: limit,
            before: before,
            until: until
        ))
    }

    func getTransaction(signature: String) async throws -> RpcTransactionResponse? {
        try await fetch(rpc: GetTransactionJsonRpc(signature: signature))
    }

    func sendTransaction(serializedBase64: String) async throws -> String {
        try await fetch(rpc: SendTransactionJsonRpc(base64EncodedTransaction: serializedBase64))
    }

    func getLatestBlockhash() async throws -> RpcBlockhashResponse {
        try await fetch(rpc: GetLatestBlockhashJsonRpc())
    }

    func getMultipleAccounts(addresses: [String]) async throws -> [BufferInfo?] {
        try await fetch(rpc: GetMultipleAccountsJsonRpc(addresses: addresses))
    }
}
