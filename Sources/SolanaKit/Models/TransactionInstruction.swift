import Foundation

/// A single uncompiled Solana instruction.
///
/// Contains the on-chain program to invoke, the ordered list of account metas
/// it requires, and the raw instruction data bytes. This is the input type for
/// `SolanaSerializer.compile()` and will also be produced by program builders
/// such as `SystemProgram` and `TokenProgram` in later milestones.
struct TransactionInstruction {
    /// The on-chain program being invoked.
    let programId: PublicKey
    /// Ordered account metas required by the instruction.
    let keys: [AccountMeta]
    /// Arbitrary instruction data bytes (program-specific encoding).
    let data: Data
}
