import Foundation
import HsToolKit

final class TokenAccountSignatureProvider: ISignatureProvider {
    private let pageSize = 100
    private let maxFirstSyncPages = 3

    private let rpcApiProvider: IRpcApiProvider
    private let storage: ITransactionStorage
    private let logger: Logger?

    private var pendingCursors: [String: String] = [:]
    private var cachedBalances: [String: String] = [:]
    private var pendingBalances: [String: String] = [:]

    init(rpcApiProvider: IRpcApiProvider, storage: ITransactionStorage, logger: Logger? = nil) {
        self.rpcApiProvider = rpcApiProvider
        self.storage = storage
        self.logger = logger
    }

    func fetchNewSignatures() async throws -> [SignatureInfo] {
        let allAccounts = storage.fungibleTokenAccounts()
        guard !allAccounts.isEmpty else { return [] }

        let currentBalances = Dictionary(uniqueKeysWithValues: allAccounts.map { ($0.address, $0.balance) })
        let changedAccounts: [TokenAccount]

        if cachedBalances.isEmpty {
            changedAccounts = allAccounts
        } else {
            changedAccounts = allAccounts.filter { cachedBalances[$0.address] != $0.balance }
            guard !changedAccounts.isEmpty else { return [] }
        }

        pendingBalances = currentBalances

        var allSignatures: [SignatureInfo] = []
        pendingCursors = [:]

        for account in changedAccounts {
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

                if let newestSignature = ataSignatures.first?.signature {
                    pendingCursors[cursorName] = newestSignature
                }

                allSignatures.append(contentsOf: ataSignatures)
            } catch {
                logger?.error("TokenAccountSignatureProvider: ATA \(ataAddress) failed: \(error)")
                continue
            }
        }

        return allSignatures
    }

    func commitCursors() throws {
        for (cursorName, signature) in pendingCursors {
            try storage.save(lastSyncedTransaction: LastSyncedTransaction(
                syncSourceName: cursorName,
                hash: signature
            ))
        }
        pendingCursors = [:]

        if !pendingBalances.isEmpty {
            cachedBalances = pendingBalances
            pendingBalances = [:]
        }
    }

    static func cursorName(ataAddress: String) -> String {
        "rpc/ata/\(ataAddress)"
    }
}
