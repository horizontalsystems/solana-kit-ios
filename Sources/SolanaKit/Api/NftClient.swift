import Foundation
import HsExtensions

/// Fetches Metaplex on-chain metadata for a list of SPL token mint addresses.
///
/// Derives the Metadata PDA for each mint, fetches via `getMultipleAccounts` in chunks
/// of 100 (matching Android's `NftClient.kt` chunk size), parses each returned account,
/// and filters to accounts whose owner is the Metaplex Token Metadata program.
///
/// Mirrors Android's `NftClient.kt` logic, reimplemented natively since there is no
/// Swift Metaplex SDK.
final class NftClient: INftClient {

    // MARK: - Dependencies

    private let rpcApiProvider: IRpcApiProvider

    // MARK: - Constants

    private let chunkSize = 100

    // MARK: - Init

    init(rpcApiProvider: IRpcApiProvider) {
        self.rpcApiProvider = rpcApiProvider
    }

    // MARK: - INftClient

    /// Fetches and parses Metaplex metadata for each mint address.
    ///
    /// - Parameter mintAddresses: Base58 mint address strings to look up.
    /// - Returns: A dictionary keyed by mint address containing the parsed metadata.
    ///   Mints whose PDA cannot be derived, whose account is absent, or whose account
    ///   is not owned by the Metaplex program are omitted.
    func findAllByMintList(mintAddresses: [String]) async throws -> [String: MetaplexMetadataLayout] {
        guard !mintAddresses.isEmpty else { return [:] }

        // Derive metadata PDAs for each mint.
        let pdaMappings: [(mintAddress: String, pdaAddress: String)] = mintAddresses.compactMap { mintAddress in
            guard let mintKey = try? PublicKey(mintAddress),
                  let pda = try? PublicKey.metadataPDA(mintPublicKey: mintKey) else {
                return nil
            }
            return (mintAddress, pda.base58)
        }

        guard !pdaMappings.isEmpty else { return [:] }

        var result: [String: MetaplexMetadataLayout] = [:]
        let metadataProgramId = PublicKey.metaplexTokenMetadataProgramId.base58

        // Fetch in chunks of `chunkSize`.
        for chunk in pdaMappings.hs.chunked(into: chunkSize) {
            let pdaAddresses = chunk.map { $0.pdaAddress }
            let bufferInfos = try await rpcApiProvider.getMultipleAccounts(addresses: pdaAddresses)

            for (index, item) in chunk.enumerated() {
                guard index < bufferInfos.count,
                      let bufferInfo = bufferInfos[index],
                      bufferInfo.owner == metadataProgramId,
                      let layout = try? MetaplexMetadataLayout(data: bufferInfo.data) else {
                    continue
                }
                result[item.mintAddress] = layout
            }
        }

        return result
    }
}
