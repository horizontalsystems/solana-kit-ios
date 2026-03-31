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
        logger?.debug("WalletSignatureProvider: fetching for \(address), until: \(until ?? "nil")")

        var allSignatures: [SignatureInfo] = []
        var before: String?

        repeat {
            let chunk = try await rpcApiProvider.getSignaturesForAddress(
                address: address,
                limit: pageSize,
                before: before,
                until: until
            )
            allSignatures.append(contentsOf: chunk)
            before = chunk.last?.signature
            if chunk.count < pageSize { break }
        } while true

        // Save cursor on success.
        if let newestSignature = allSignatures.first {
            try? storage.save(lastSyncedTransaction: LastSyncedTransaction(
                syncSourceName: Self.syncSourceName,
                hash: newestSignature
            ))
        }

        logger?.debug("WalletSignatureProvider: fetched \(allSignatures.count) signature(s)")
        return allSignatures
    }
}
