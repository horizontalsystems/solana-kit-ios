import Foundation
import HsToolKit

/// Fetches transaction signatures for all known fungible Associated Token Accounts (ATAs)
/// via `getSignaturesForAddress`.
///
/// Discovers incoming SPL transfers where the wallet address is only the token
/// account owner, not a direct transaction participant.
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

    init(rpcApiProvider: IRpcApiProvider, storage: ITransactionStorage, logger: Logger? = nil) {
        self.rpcApiProvider = rpcApiProvider
        self.storage = storage
        self.logger = logger
    }

    func fetchNewSignatures() async throws -> [SignatureInfo] {
        let tokenAccounts = storage.fungibleTokenAccounts()
        guard !tokenAccounts.isEmpty else {
            logger?.debug("TokenAccountSignatureProvider: no fungible token accounts, skipping")
            return []
        }

        logger?.debug("TokenAccountSignatureProvider: syncing \(tokenAccounts.count) ATA(s)")

        var allSignatures: [SignatureInfo] = []
        var ataSuccessCount = 0
        var ataFailCount = 0
        pendingCursors = [:]

        for account in tokenAccounts {
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
        guard !pendingCursors.isEmpty else { return }
        for (cursorName, signature) in pendingCursors {
            try storage.save(lastSyncedTransaction: LastSyncedTransaction(
                syncSourceName: cursorName,
                hash: signature
            ))
        }
        logger?.debug("TokenAccountSignatureProvider: committed \(pendingCursors.count) cursor(s)")
        pendingCursors = [:]
    }

    static func cursorName(ataAddress: String) -> String {
        "rpc/ata/\(ataAddress)"
    }
}
