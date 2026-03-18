/// Internal protocol definitions for SolanaKit.
///
/// Every infrastructure type is accessed through a protocol so that
/// managers can be unit-tested with mock implementations.

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
