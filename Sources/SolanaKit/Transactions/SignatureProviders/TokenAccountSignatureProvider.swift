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

        for account in tokenAccounts {
            let ataAddress = account.address
            let cursorName = Self.cursorName(ataAddress: ataAddress)
            let until = storage.lastSyncedTransaction(syncSourceName: cursorName)?.hash
            let isFirstSync = until == nil

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
                    ataSignatures.append(contentsOf: chunk)
                    before = chunk.last?.signature
                    pageCount += 1

                    if chunk.count < pageSize { break }
                    if isFirstSync, pageCount >= maxFirstSyncPages { break }
                } while true

                if let newestSignature = ataSignatures.first {
                    try? storage.save(lastSyncedTransaction: LastSyncedTransaction(
                        syncSourceName: cursorName,
                        hash: newestSignature
                    ))
                    logger?.debug("TokenAccountSignatureProvider: ATA \(ataAddress) — \(ataSignatures.count) new signature(s)")
                }

                allSignatures.append(contentsOf: ataSignatures)
            } catch {
                logger?.error("TokenAccountSignatureProvider: ATA \(ataAddress) failed: \(error), skipping")
                continue
            }
        }

        logger?.debug("TokenAccountSignatureProvider: total \(allSignatures.count) signature(s)")
        return allSignatures
    }

    static func cursorName(ataAddress: String) -> String {
        "rpc/ata/\(ataAddress)"
    }
}
