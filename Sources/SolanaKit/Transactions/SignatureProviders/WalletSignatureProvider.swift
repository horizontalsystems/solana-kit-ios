import Foundation
import HsToolKit

/// Fetches transaction signatures for the main wallet address via `getSignaturesForAddress`.
///
/// Manages its own incremental sync cursor under `"rpc/wallet"`.
final class WalletSignatureProvider: ISignatureProvider {
    private static let syncSourceName = "rpc/wallet"
    private let pageSize = 1000

    private let address: String
    private let rpcApiProvider: IRpcApiProvider
    private let storage: ITransactionStorage
    private let logger: Logger?

    init(address: String, rpcApiProvider: IRpcApiProvider, storage: ITransactionStorage, logger: Logger? = nil) {
        self.address = address
        self.rpcApiProvider = rpcApiProvider
        self.storage = storage
        self.logger = logger
    }

    func fetchNewSignatures() async throws -> [SignatureInfo] {
        let until = storage.lastSyncedTransaction(syncSourceName: Self.syncSourceName)?.hash
        logger?.debug("WalletSignatureProvider: fetching for \(address), cursor: \(until ?? "nil")")

        var allSignatures: [SignatureInfo] = []
        var before: String?
        var pageNumber = 0

        repeat {
            pageNumber += 1
            let chunk = try await rpcApiProvider.getSignaturesForAddress(
                address: address,
                limit: pageSize,
                before: before,
                until: until
            )
            logger?.debug("WalletSignatureProvider: page \(pageNumber) returned \(chunk.count) signature(s)")
            allSignatures.append(contentsOf: chunk)
            before = chunk.last?.signature
            if chunk.count < pageSize { break }
        } while true

        // Save cursor on success.
        if let newestSignature = allSignatures.first?.signature {
            try? storage.save(lastSyncedTransaction: LastSyncedTransaction(
                syncSourceName: Self.syncSourceName,
                hash: newestSignature
            ))
            logger?.debug("WalletSignatureProvider: saved cursor \(newestSignature)")
        }

        logger?.debug("WalletSignatureProvider: total \(allSignatures.count) signature(s) in \(pageNumber) page(s)")
        return allSignatures
    }
}
