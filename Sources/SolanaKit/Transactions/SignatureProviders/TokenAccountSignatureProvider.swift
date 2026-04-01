import Foundation
import HsToolKit

/// Fetches transaction signatures for fungible ATAs whose balance changed.
///
/// On each sync cycle, compares current ATA balances (from `TokenAccountManager.sync()` which
/// runs before `TransactionSyncer.sync()`) with the last committed snapshot. Only queries
/// `getSignaturesForAddress` for ATAs with a balance change — 0 extra RPC calls in steady-state.
///
/// Balance cache is updated ONLY in `commitCursors()` — if sync fails, the cache stays stale
/// and the next cycle re-detects the same changes (no data loss).
///
/// Each ATA has an independent sync cursor stored under `"rpc/ata/<ata_address>"`.
/// Individual ATA failures are logged and skipped — remaining ATAs continue syncing.
final class TokenAccountSignatureProvider: ISignatureProvider {
    private let pageSize = 100
    private let maxFirstSyncPages = 3

    private let rpcApiProvider: IRpcApiProvider
    private let storage: ITransactionStorage
    private let logger: Logger?

    /// Per-ATA cursors staged for commit. Key = cursorName, Value = newest signature.
    private var pendingCursors: [String: String] = [:]

    /// Last-known ATA balances — updated ONLY on commitCursors().
    private var cachedBalances: [String: String] = [:]

    /// Balances snapshot from the latest fetch — staged for commit.
    private var pendingBalances: [String: String] = [:]

    init(rpcApiProvider: IRpcApiProvider, storage: ITransactionStorage, logger: Logger? = nil) {
        self.rpcApiProvider = rpcApiProvider
        self.storage = storage
        self.logger = logger
    }

    func fetchNewSignatures() async throws -> [SignatureInfo] {
        let allAccounts = storage.fungibleTokenAccounts()
        guard !allAccounts.isEmpty else {
            logger?.debug("TokenAccountSignatureProvider: no fungible token accounts, skipping")
            return []
        }

        // Detect which ATAs have changed balance since last committed sync.
        let currentBalances = Dictionary(uniqueKeysWithValues: allAccounts.map { ($0.address, $0.balance) })
        let changedAccounts: [TokenAccount]

        if cachedBalances.isEmpty {
            // First run after Kit creation — sync all ATAs to establish cursors.
            changedAccounts = allAccounts
            logger?.debug("TokenAccountSignatureProvider: first run, syncing all \(allAccounts.count) ATA(s)")
        } else {
            changedAccounts = allAccounts.filter { account in
                cachedBalances[account.address] != account.balance
            }
            if changedAccounts.isEmpty {
                logger?.debug("TokenAccountSignatureProvider: no balance changes in \(allAccounts.count) ATA(s), skipping")
                return []
            }
            logger?.debug("TokenAccountSignatureProvider: \(changedAccounts.count)/\(allAccounts.count) ATA(s) have balance changes")
        }

        // Stage balances for commit — do NOT update cachedBalances here.
        pendingBalances = currentBalances

        var allSignatures: [SignatureInfo] = []
        var ataSuccessCount = 0
        var ataFailCount = 0
        pendingCursors = [:]

        for account in changedAccounts {
            let ataAddress = account.address
            let mintAddress = account.mintAddress
            let cursorName = Self.cursorName(ataAddress: ataAddress)
            let until = storage.lastSyncedTransaction(syncSourceName: cursorName)?.hash
            let isFirstSync = until == nil

            logger?.debug("TokenAccountSignatureProvider: ATA \(ataAddress) (mint: \(mintAddress)), cursor: \(until ?? "nil"), firstSync: \(isFirstSync)")

            do {
                var ataSignatures: [SignatureInfo] = []
                var before: String?
                var pageCount = 0

                repeat {
                    let chunk = try await rpcApiProvider.getSignaturesForAddress(
                        address: ataAddress,
                        limit: pageSize,
                        before: before,
                        until: until
                    )
                    logger?.debug("TokenAccountSignatureProvider: ATA \(ataAddress) page \(pageCount + 1) returned \(chunk.count) signature(s)")
                    ataSignatures.append(contentsOf: chunk)
                    before = chunk.last?.signature
                    pageCount += 1

                    if chunk.count < pageSize { break }
                    if isFirstSync, pageCount >= maxFirstSyncPages { break }
                } while true

                if let newestSignature = ataSignatures.first?.signature {
                    pendingCursors[cursorName] = newestSignature
                    logger?.debug("TokenAccountSignatureProvider: ATA \(ataAddress) — \(ataSignatures.count) new signature(s), staged cursor \(newestSignature)")
                }

                allSignatures.append(contentsOf: ataSignatures)
                ataSuccessCount += 1
            } catch {
                ataFailCount += 1
                logger?.error("TokenAccountSignatureProvider: ATA \(ataAddress) (mint: \(mintAddress)) failed: \(error), skipping")
                continue
            }
        }

        logger?.debug("TokenAccountSignatureProvider: done — \(allSignatures.count) signature(s), \(ataSuccessCount) ATA(s) ok, \(ataFailCount) failed")
        return allSignatures
    }

    func commitCursors() throws {
        // Commit ATA signature cursors.
        if !pendingCursors.isEmpty {
            for (cursorName, signature) in pendingCursors {
                try storage.save(lastSyncedTransaction: LastSyncedTransaction(
                    syncSourceName: cursorName,
                    hash: signature
                ))
            }
            logger?.debug("TokenAccountSignatureProvider: committed \(pendingCursors.count) cursor(s)")
            pendingCursors = [:]
        }

        // Commit balance cache — only after successful persist.
        if !pendingBalances.isEmpty {
            cachedBalances = pendingBalances
            pendingBalances = [:]
            logger?.debug("TokenAccountSignatureProvider: committed balance cache (\(cachedBalances.count) ATA(s))")
        }
    }

    static func cursorName(ataAddress: String) -> String {
        "rpc/ata/\(ataAddress)"
    }
}
