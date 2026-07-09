import Foundation

/// Program ids the kit RECOGNIZES and surfaces on `Transaction.programIds`, so clients can
/// classify transactions (e.g. render a Jupiter interaction as a swap instead of an unknown
/// multi-transfer). Deliberately a small allowlist — and callers must pass INVOKED program ids
/// (from the transaction's instructions), never raw `accountKeys`: account keys mix programs
/// with ordinary accounts, so presence there does not mean the program ran (a wallet merely
/// RECEIVING the tail of someone else's swap would be mislabeled).
///
/// Extend by appending — the stored value is just the id string, so older rows stay valid.
public enum KnownPrograms {
    /// Jupiter aggregator v6 (`jupiterSwapProgramId`).
    public static let jupiterV6 = "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4"

    /// LI.FI executor program (logs "LI.FI TX"); the entry point of a LI.FI Solana swap/bridge.
    public static let lifi = "3i5JeuZuUxeKtVysUnwQNGerJP2bSMX9fTFfS4Nxe3Br"

    /// All recognized program ids.
    public static let all: Set<String> = [jupiterV6, lifi]

    /// The recognized subset of `candidates`, deduplicated (first occurrence wins, order
    /// preserved) and space-joined for `Transaction.programIds`; `nil` when none are recognized.
    /// Deduplication matters because callers pass one candidate per INSTRUCTION — a program
    /// invoked twice in one transaction must still yield a single entry.
    static func recognized(in candidates: [String]) -> String? {
        var seen = Set<String>()
        let hits = candidates.filter { all.contains($0) && seen.insert($0).inserted }
        return hits.isEmpty ? nil : hits.joined(separator: " ")
    }
}
