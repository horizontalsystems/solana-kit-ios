import Foundation
import GRDB

/// GRDB-backed storage for the transaction database.
///
/// Stores five tables:
/// - `transactions` — raw transaction records (SOL + SPL wrappers)
/// - `tokenTransfers` — SPL token transfer events (many-to-one with transactions)
/// - `tokenAccounts` — SPL token accounts owned by the watched address
/// - `mintAccounts` — token mint metadata
/// - `lastSyncedTransactions` — incremental sync cursors keyed by syncer name
///
/// Each wallet gets its own database file (`transactions-<walletId>.sqlite`).
/// The `address` parameter is the owner wallet address used for direction filtering in queries.
///
/// Follows EvmKit's `TransactionStorage` pattern: `DatabasePool` opened with `try!`,
/// migrations run with `try?`, reads with `try!`, writes propagate `throws`.
final class TransactionStorage {
    private let dbPool: DatabasePool
    private let address: String

    // MARK: - Init

    init(databaseDirectoryUrl: URL, databaseFileName: String, address: String) {
        let databaseURL = databaseDirectoryUrl
            .appendingPathComponent("\(databaseFileName).sqlite")

        self.address = address
        dbPool = try! DatabasePool(path: databaseURL.path)

        try? migrator.migrate(dbPool)
    }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createTransactionTables") { db in
            // transactions
            try db.create(table: Transaction.databaseTableName) { t in
                t.column(Transaction.Columns.hash.name, .text).notNull()
                t.column(Transaction.Columns.timestamp.name, .integer).notNull()
                t.column(Transaction.Columns.fee.name, .text)
                t.column(Transaction.Columns.from.name, .text)
                t.column(Transaction.Columns.to.name, .text)
                t.column(Transaction.Columns.amount.name, .text)
                t.column(Transaction.Columns.error.name, .text)
                t.column(Transaction.Columns.pending.name, .boolean).notNull()
                t.column(Transaction.Columns.blockHash.name, .text).notNull()
                t.column(Transaction.Columns.lastValidBlockHeight.name, .integer).notNull()
                t.column(Transaction.Columns.base64Encoded.name, .text).notNull()
                t.column(Transaction.Columns.retryCount.name, .integer).notNull()
                t.primaryKey([Transaction.Columns.hash.name], onConflict: .replace)
            }

            // tokenTransfers
            try db.create(table: TokenTransfer.databaseTableName) { t in
                t.autoIncrementedPrimaryKey(TokenTransfer.Columns.id.name)
                t.column(TokenTransfer.Columns.transactionHash.name, .text)
                    .notNull()
                    .references(Transaction.databaseTableName, onDelete: .cascade)
                    .indexed()
                t.column(TokenTransfer.Columns.mintAddress.name, .text).notNull()
                t.column(TokenTransfer.Columns.incoming.name, .boolean).notNull()
                t.column(TokenTransfer.Columns.amount.name, .text).notNull()
            }

            // tokenAccounts
            try db.create(table: TokenAccount.databaseTableName) { t in
                t.column(TokenAccount.Columns.address.name, .text).notNull()
                t.column(TokenAccount.Columns.mintAddress.name, .text).notNull()
                t.column(TokenAccount.Columns.balance.name, .text).notNull()
                t.column(TokenAccount.Columns.decimals.name, .integer).notNull()
                t.primaryKey([TokenAccount.Columns.address.name], onConflict: .replace)
            }

            // mintAccounts
            try db.create(table: MintAccount.databaseTableName) { t in
                t.column(MintAccount.Columns.address.name, .text).notNull()
                t.column(MintAccount.Columns.decimals.name, .integer).notNull()
                t.column(MintAccount.Columns.supply.name, .integer)
                t.column(MintAccount.Columns.isNft.name, .boolean).notNull()
                t.column(MintAccount.Columns.name.name, .text)
                t.column(MintAccount.Columns.symbol.name, .text)
                t.column(MintAccount.Columns.uri.name, .text)
                t.column(MintAccount.Columns.collectionAddress.name, .text)
                t.primaryKey([MintAccount.Columns.address.name], onConflict: .ignore)
            }

            // lastSyncedTransactions
            try db.create(table: LastSyncedTransaction.databaseTableName) { t in
                t.column(LastSyncedTransaction.Columns.syncSourceName.name, .text).notNull()
                t.column(LastSyncedTransaction.Columns.hash.name, .text).notNull()
                t.primaryKey([LastSyncedTransaction.Columns.syncSourceName.name], onConflict: .replace)
            }
        }

        return migrator
    }

    // MARK: - Convenience initializer (wallet-scoped)

    /// Creates (or opens) the transaction database for the given wallet under
    /// `Application Support/solana-kit/transactions-<walletId>.sqlite`.
    convenience init(walletId: String, address: String) throws {
        let fileManager = FileManager.default
        let url = try fileManager
            .url(for: .applicationSupportDirectory,
                 in: .userDomainMask,
                 appropriateFor: nil,
                 create: true)
            .appendingPathComponent("solana-kit", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        self.init(
            databaseDirectoryUrl: url,
            databaseFileName: "transactions-\(walletId)",
            address: address
        )
    }

    // MARK: - Static cleanup

    /// Removes all database files for the given wallet.
    /// Called by `Kit.clear(walletId:)` during wallet removal.
    static func clear(walletId: String) throws {
        let fileManager = FileManager.default
        let url = try fileManager
            .url(for: .applicationSupportDirectory,
                 in: .userDomainMask,
                 appropriateFor: nil,
                 create: true)
            .appendingPathComponent("solana-kit", isDirectory: true)

        let baseName = "transactions-\(walletId)"
        let extensions = ["sqlite", "sqlite-wal", "sqlite-shm"]

        for ext in extensions {
            let fileURL = url.appendingPathComponent("\(baseName).\(ext)")
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }

    // MARK: - Private query builder

    private func fetchTransactions(
        typeCondition: String?,
        typeArgs: [DatabaseValueConvertible] = [],
        joinTokenTransfers: Bool,
        fromHash: String?,
        limit: Int?
    ) -> [FullTransaction] {
        try! dbPool.read { db in
            var sql = "SELECT DISTINCT tx.* FROM \(Transaction.databaseTableName) AS tx"

            if joinTokenTransfers {
                sql += " LEFT JOIN \(TokenTransfer.databaseTableName) AS tt ON tx.\(Transaction.Columns.hash.name) = tt.\(TokenTransfer.Columns.transactionHash.name)"
            }

            var conditions: [String] = []
            var args: [DatabaseValueConvertible] = []

            if let fromHash = fromHash,
               let fromTx = try Transaction.filter(Transaction.Columns.hash == fromHash).fetchOne(db) {
                conditions.append("(tx.\(Transaction.Columns.timestamp.name) < ? OR (tx.\(Transaction.Columns.timestamp.name) = ? AND tx.\(Transaction.Columns.hash.name) < ?))")
                args.append(fromTx.timestamp)
                args.append(fromTx.timestamp)
                args.append(fromTx.hash)
            }

            if let typeCondition = typeCondition {
                conditions.append(typeCondition)
                args.append(contentsOf: typeArgs)
            }

            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }

            sql += " ORDER BY tx.\(Transaction.Columns.timestamp.name) DESC, tx.\(Transaction.Columns.hash.name) DESC"

            if let limit = limit {
                sql += " LIMIT \(limit)"
            }

            let statement = try db.makeStatement(sql: sql)
            let rows = try Row.fetchAll(statement, arguments: StatementArguments(args))
            let transactions = try rows.map { try Transaction(row: $0) }

            return try transactions.map { tx in
                let tokenTransfers = try TokenTransfer
                    .filter(TokenTransfer.Columns.transactionHash == tx.hash)
                    .fetchAll(db)

                let fullTokenTransfers = try tokenTransfers.map { tt -> FullTokenTransfer in
                    let mint = try MintAccount
                        .filter(MintAccount.Columns.address == tt.mintAddress)
                        .fetchOne(db)
                    return FullTokenTransfer(
                        tokenTransfer: tt,
                        mintAccount: mint ?? MintAccount(address: tt.mintAddress, decimals: 0)
                    )
                }

                return FullTransaction(transaction: tx, tokenTransfers: fullTokenTransfers)
            }
        }
    }
}

// MARK: - ITransactionStorage

extension TransactionStorage: ITransactionStorage {

    // MARK: Transaction CRUD

    func save(transactions: [Transaction]) throws {
        try dbPool.write { db in
            for transaction in transactions {
                try transaction.save(db)
            }
        }
    }

    func transaction(hash: String) -> Transaction? {
        try! dbPool.read { db in
            try Transaction.filter(Transaction.Columns.hash == hash).fetchOne(db)
        }
    }

    func pendingTransactions() -> [Transaction] {
        try! dbPool.read { db in
            try Transaction
                .filter(Transaction.Columns.pending == true)
                .order(Transaction.Columns.timestamp)
                .fetchAll(db)
        }
    }

    func lastNonPendingTransaction() -> Transaction? {
        try! dbPool.read { db in
            try Transaction
                .filter(Transaction.Columns.pending == false)
                .order(Transaction.Columns.timestamp.desc)
                .fetchOne(db)
        }
    }

    func updateTransactions(_ transactions: [Transaction]) throws {
        try dbPool.write { db in
            for transaction in transactions {
                try transaction.update(db)
            }
        }
    }

    // MARK: TokenTransfer

    func save(tokenTransfers: [TokenTransfer]) throws {
        try dbPool.write { db in
            for tokenTransfer in tokenTransfers {
                try tokenTransfer.save(db)
            }
        }
    }

    // MARK: MintAccount

    func save(mintAccounts: [MintAccount]) throws {
        try dbPool.write { db in
            for mintAccount in mintAccounts {
                try mintAccount.save(db)
            }
        }
    }

    func addMintAccount(_ mintAccount: MintAccount) throws {
        try dbPool.write { db in
            try mintAccount.save(db)
        }
    }

    func mintAccount(address: String) -> MintAccount? {
        try! dbPool.read { db in
            try MintAccount.filter(MintAccount.Columns.address == address).fetchOne(db)
        }
    }

    // MARK: TokenAccount

    func save(tokenAccounts: [TokenAccount]) throws {
        try dbPool.write { db in
            for tokenAccount in tokenAccounts {
                try tokenAccount.save(db)
            }
        }
    }

    func addTokenAccount(_ tokenAccount: TokenAccount) throws {
        try dbPool.write { db in
            try tokenAccount.save(db)
        }
    }

    func tokenAccount(mintAddress: String) -> TokenAccount? {
        try! dbPool.read { db in
            try TokenAccount
                .filter(TokenAccount.Columns.mintAddress == mintAddress)
                .fetchOne(db)
        }
    }

    func allTokenAccounts() -> [TokenAccount] {
        try! dbPool.read { db in
            try TokenAccount.fetchAll(db)
        }
    }

    func tokenAccounts(mintAddresses: [String]) -> [TokenAccount] {
        try! dbPool.read { db in
            try TokenAccount
                .filter(mintAddresses.contains(TokenAccount.Columns.mintAddress))
                .fetchAll(db)
        }
    }

    func tokenAccountExists(mintAddress: String) -> Bool {
        try! dbPool.read { db in
            try TokenAccount
                .filter(TokenAccount.Columns.mintAddress == mintAddress)
                .fetchOne(db) != nil
        }
    }

    func fullTokenAccount(mintAddress: String) -> FullTokenAccount? {
        try! dbPool.read { db in
            guard let tokenAcc = try TokenAccount
                .filter(TokenAccount.Columns.mintAddress == mintAddress)
                .fetchOne(db) else { return nil }
            let mintAcc = try MintAccount
                .filter(MintAccount.Columns.address == tokenAcc.mintAddress)
                .fetchOne(db) ?? MintAccount(address: tokenAcc.mintAddress, decimals: 0)
            return FullTokenAccount(tokenAccount: tokenAcc, mintAccount: mintAcc)
        }
    }

    func fullTokenAccounts() -> [FullTokenAccount] {
        try! dbPool.read { db in
            let tokenAccounts = try TokenAccount.fetchAll(db)
            return try tokenAccounts.map { tokenAcc in
                let mintAcc = try MintAccount
                    .filter(MintAccount.Columns.address == tokenAcc.mintAddress)
                    .fetchOne(db) ?? MintAccount(address: tokenAcc.mintAddress, decimals: 0)
                return FullTokenAccount(tokenAccount: tokenAcc, mintAccount: mintAcc)
            }
        }
    }

    // MARK: Syncer state

    func lastSyncedTransaction(syncSourceName: String) -> LastSyncedTransaction? {
        try! dbPool.read { db in
            try LastSyncedTransaction
                .filter(LastSyncedTransaction.Columns.syncSourceName == syncSourceName)
                .fetchOne(db)
        }
    }

    func save(lastSyncedTransaction: LastSyncedTransaction) throws {
        try dbPool.write { db in
            try lastSyncedTransaction.save(db)
        }
    }

    // MARK: Complex queries

    func transactions(incoming: Bool?, fromHash: String?, limit: Int?) -> [FullTransaction] {
        let typeCondition: String?
        let typeArgs: [DatabaseValueConvertible]
        let joinTokenTransfers: Bool

        switch incoming {
        case .none:
            typeCondition = nil
            typeArgs = []
            joinTokenTransfers = false
        case .some(true):
            typeCondition = "((tx.\(Transaction.Columns.amount.name) IS NOT NULL AND tx.\"to\" = ?) OR tt.\(TokenTransfer.Columns.incoming.name))"
            typeArgs = [address]
            joinTokenTransfers = true
        case .some(false):
            typeCondition = "((tx.\(Transaction.Columns.amount.name) IS NOT NULL AND tx.\"from\" = ?) OR NOT(tt.\(TokenTransfer.Columns.incoming.name)))"
            typeArgs = [address]
            joinTokenTransfers = true
        }

        return fetchTransactions(
            typeCondition: typeCondition,
            typeArgs: typeArgs,
            joinTokenTransfers: joinTokenTransfers,
            fromHash: fromHash,
            limit: limit
        )
    }

    func solTransactions(incoming: Bool?, fromHash: String?, limit: Int?) -> [FullTransaction] {
        let typeCondition: String
        let typeArgs: [DatabaseValueConvertible]

        switch incoming {
        case .none:
            typeCondition = "tx.\(Transaction.Columns.amount.name) IS NOT NULL"
            typeArgs = []
        case .some(true):
            typeCondition = "(tx.\(Transaction.Columns.amount.name) IS NOT NULL AND tx.\"to\" = ?)"
            typeArgs = [address]
        case .some(false):
            typeCondition = "(tx.\(Transaction.Columns.amount.name) IS NOT NULL AND tx.\"from\" = ?)"
            typeArgs = [address]
        }

        return fetchTransactions(
            typeCondition: typeCondition,
            typeArgs: typeArgs,
            joinTokenTransfers: false,
            fromHash: fromHash,
            limit: limit
        )
    }

    func splTransactions(mintAddress: String, incoming: Bool?, fromHash: String?, limit: Int?) -> [FullTransaction] {
        let typeCondition: String
        let typeArgs: [DatabaseValueConvertible]

        switch incoming {
        case .none:
            typeCondition = "tt.\(TokenTransfer.Columns.mintAddress.name) = ?"
            typeArgs = [mintAddress]
        case .some(true):
            typeCondition = "(tt.\(TokenTransfer.Columns.mintAddress.name) = ? AND tt.\(TokenTransfer.Columns.incoming.name))"
            typeArgs = [mintAddress]
        case .some(false):
            typeCondition = "(tt.\(TokenTransfer.Columns.mintAddress.name) = ? AND NOT(tt.\(TokenTransfer.Columns.incoming.name)))"
            typeArgs = [mintAddress]
        }

        return fetchTransactions(
            typeCondition: typeCondition,
            typeArgs: typeArgs,
            joinTokenTransfers: true,
            fromHash: fromHash,
            limit: limit
        )
    }

    func fullTransactions(hashes: [String]) -> [FullTransaction] {
        guard !hashes.isEmpty else { return [] }

        return try! dbPool.read { db in
            let placeholders = hashes.map { _ in "?" }.joined(separator: ", ")
            let sql = "SELECT DISTINCT tx.* FROM \(Transaction.databaseTableName) AS tx WHERE tx.\(Transaction.Columns.hash.name) IN (\(placeholders))"
            let args = hashes.map { $0 as DatabaseValueConvertible }
            let statement = try db.makeStatement(sql: sql)
            let rows = try Row.fetchAll(statement, arguments: StatementArguments(args))
            let transactions = try rows.map { try Transaction(row: $0) }

            return try transactions.map { tx in
                let tokenTransfers = try TokenTransfer
                    .filter(TokenTransfer.Columns.transactionHash == tx.hash)
                    .fetchAll(db)

                let fullTokenTransfers = try tokenTransfers.map { tt -> FullTokenTransfer in
                    let mint = try MintAccount
                        .filter(MintAccount.Columns.address == tt.mintAddress)
                        .fetchOne(db)
                    return FullTokenTransfer(
                        tokenTransfer: tt,
                        mintAccount: mint ?? MintAccount(address: tt.mintAddress, decimals: 0)
                    )
                }

                return FullTransaction(transaction: tx, tokenTransfers: fullTokenTransfers)
            }
        }
    }
}
