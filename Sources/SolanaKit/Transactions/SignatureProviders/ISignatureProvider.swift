import Foundation

/// Abstraction for fetching new transaction signatures.
///
/// Two-phase commit: `fetchNewSignatures()` returns data without advancing cursors,
/// `commitCursors()` is called only after the caller successfully processes the data.
/// This prevents cursor advancement on transient failures (network, parsing).
protocol ISignatureProvider {
    /// Fetches all new signatures since the provider's last saved cursor.
    /// Does NOT advance cursors — call `commitCursors()` after successful processing.
    func fetchNewSignatures() async throws -> [SignatureInfo]

    /// Advances cursors to the newest signatures returned by the last `fetchNewSignatures()`.
    /// Call only after the returned signatures have been successfully persisted.
    func commitCursors() throws
}
