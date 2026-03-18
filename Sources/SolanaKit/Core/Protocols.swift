/// Internal protocol definitions for SolanaKit.
///
/// Every infrastructure type is accessed through a protocol so that
/// managers can be unit-tested with mock implementations.

// MARK: - RPC provider protocol

protocol IRpcApiProvider {
    var source: String { get }
    func fetch<T>(rpc: JsonRpc<T>) async throws -> T
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
