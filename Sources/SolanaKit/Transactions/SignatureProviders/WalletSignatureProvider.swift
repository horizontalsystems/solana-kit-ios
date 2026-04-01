import Foundation
import HsToolKit

final class WalletSignatureProvider: ISignatureProvider {
    private static let syncSourceName = "rpc/wallet"
    private let pageSize = 1000

    private let address: String
    private let rpcApiProvider: IRpcApiProvider
    private let storage: ITransactionStorage

    private var pendingCursor: String?

    init(address: String, rpcApiProvider: IRpcApiProvider, storage: ITransactionStorage, logger _: Logger? = nil) {
        self.address = address
        self.rpcApiProvider = rpcApiProvider
        self.storage = storage
    }

    func fetchNewSignatures() async throws -> [SignatureInfo] {
        let until = storage.lastSyncedTransaction(syncSourceName: Self.syncSourceName)?.hash

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

        pendingCursor = allSignatures.first?.signature
        return allSignatures
    }

    func commitCursors() throws {
        guard let cursor = pendingCursor else { return }
        try storage.save(lastSyncedTransaction: LastSyncedTransaction(
            syncSourceName: Self.syncSourceName,
            hash: cursor
        ))
        pendingCursor = nil
    }
}
