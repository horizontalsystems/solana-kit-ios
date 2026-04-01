import Foundation
import HsToolKit

/// Composes multiple `ISignatureProvider` instances and merges their results.
///
/// Deduplicates signatures (the same transaction can appear from both wallet
/// and ATA providers). Each child provider manages its own cursors internally.
final class CompositeSignatureProvider: ISignatureProvider {
    private let providers: [ISignatureProvider]
    private let logger: Logger?

    init(providers: [ISignatureProvider], logger: Logger? = nil) {
        self.providers = providers
        self.logger = logger
    }

    func fetchNewSignatures() async throws -> [SignatureInfo] {
        var allSignatures: [SignatureInfo] = []

        for provider in providers {
            let signatures = try await provider.fetchNewSignatures()
            allSignatures.append(contentsOf: signatures)
        }

        // Deduplicate by signature hash, preserving insertion order.
        var seen = Set<String>()
        let unique = allSignatures.filter { seen.insert($0.signature).inserted }

        let duplicateCount = allSignatures.count - unique.count
        if duplicateCount > 0 {
            logger?.debug("CompositeSignatureProvider: removed \(duplicateCount) duplicate(s)")
        }

        logger?.debug("CompositeSignatureProvider: \(unique.count) unique signature(s) from \(providers.count) provider(s)")
        return unique
    }

    func commitCursors() throws {
        for provider in providers {
            try provider.commitCursors()
        }
    }
}
