/// Internal protocol definitions for SolanaKit.
///
/// Every infrastructure type is accessed through a protocol so that
/// managers can be unit-tested with mock implementations.

// MARK: - Storage protocols

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
