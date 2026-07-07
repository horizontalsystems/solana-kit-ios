import Foundation

/// Program ids the kit RECOGNIZES and surfaces on `Transaction.programIds`, so clients can
/// classify transactions (e.g. render a Jupiter interaction as a swap instead of an unknown
/// multi-transfer). Deliberately a small allowlist: transaction `accountKeys` mix programs with
/// ordinary accounts, so only ids listed here are ever recorded.
///
/// Extend by appending — the stored value is just the id string, so older rows stay valid.
public enum KnownPrograms {
    /// Jupiter aggregator v6 (`jupiterSwapProgramId`).
    public static let jupiterV6 = "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4"

    /// All recognized program ids.
    public static let all: Set<String> = [jupiterV6]

    /// The recognized subset of `candidates`, space-joined for `Transaction.programIds`;
    /// `nil` when none are recognized.
    static func recognized(in candidates: [String]) -> String? {
        let hits = candidates.filter { all.contains($0) }
        return hits.isEmpty ? nil : hits.joined(separator: " ")
    }
}
