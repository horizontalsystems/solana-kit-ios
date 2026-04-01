import Foundation
import HsToolKit

final class CompositeSignatureProvider: ISignatureProvider {
    private let providers: [ISignatureProvider]

    init(providers: [ISignatureProvider], logger _: Logger? = nil) {
        self.providers = providers
    }

    func fetchNewSignatures() async throws -> [SignatureInfo] {
        var allSignatures: [SignatureInfo] = []

        for provider in providers {
            let signatures = try await provider.fetchNewSignatures()
            allSignatures.append(contentsOf: signatures)
        }

        var seen = Set<String>()
        return allSignatures.filter { seen.insert($0.signature).inserted }
    }

    func commitCursors() throws {
        for provider in providers {
            try provider.commitCursors()
        }
    }
}
