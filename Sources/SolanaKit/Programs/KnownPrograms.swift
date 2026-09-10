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

    /// DFlow aggregator. Jupiter routes some swap legs through DFlow, so a single Jupiter swap can
    /// land on-chain as two transactions — one via Jupiter v6, one via DFlow — and the DFlow leg
    /// must be recognized too or it renders as an unknown multi-transfer.
    public static let dflow = "DF1ow4tspfHX9JwWJsAb9epbkA8hmpSEAtxXy1V27QBH"

    /// SPL Associated Token Account program. Not part of `all` — it is not a swap and must not be
    /// surfaced on `Transaction.programIds` — but its presence among a transaction's INVOKED
    /// programs means the transaction created a token account, paying ~0.002 SOL of rent.
    public static let associatedTokenAccount = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"

    /// 1inch Fusion order / escrow program.
    public static let oneInchFusion = "HNarfxC3kYMMhFkxUFeYb8wHVdPzY5t9pupqW5fL2meM"

    /// All recognized program ids.
    public static let all: Set<String> = [jupiterV6, lifi, dflow, oneInchFusion]

    /// The recognized subset of `candidates`, deduplicated (first occurrence wins, order
    /// preserved) and space-joined for `Transaction.programIds`; `nil` when none are recognized.
    /// Deduplication matters because callers pass one candidate per INSTRUCTION — a program
    /// invoked twice in one transaction must still yield a single entry.
    static func recognized(in candidates: [String]) -> String? {
        var seen = Set<String>()
        let hits = candidates.filter { all.contains($0) && seen.insert($0).inserted }
        return hits.isEmpty ? nil : hits.joined(separator: " ")
    }

    /// Whether `invokedProgramIds` (INVOKED program ids, one per instruction — the same input as
    /// `recognized`) shows this transaction created an associated token account. Only top-level
    /// invocations are visible to callers, which covers wallet-built SPL sends that prepend a
    /// create-ATA instruction; an ATA created via CPI inside another program is not detected.
    static func createsTokenAccount(in invokedProgramIds: [String]) -> Bool {
        invokedProgramIds.contains(associatedTokenAccount)
    }
}
