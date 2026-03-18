import Foundation

/// A single account reference within a `TransactionInstruction`.
///
/// Tracks whether the account must sign the transaction and whether the
/// transaction may write to it. These flags drive the account-key ordering
/// and the `MessageHeader` counters in `SolanaSerializer.compile()`.
struct AccountMeta: Equatable, Hashable {
    let publicKey: PublicKey
    let isSigner: Bool
    let isWritable: Bool
}
