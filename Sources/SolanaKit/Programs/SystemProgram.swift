import Foundation

/// Instruction builders for the Solana System Program (11111111111111111111111111111111).
///
/// Caseless namespace enum — mirrors the `SolanaSerializer` pattern used throughout this package.
/// Each static method returns a `TransactionInstruction` ready to be compiled by `SolanaSerializer.compile()`.
enum SystemProgram {

    // MARK: - Transfer

    /// Builds a SOL transfer instruction.
    ///
    /// Instruction data layout (12 bytes, little-endian):
    /// - Bytes 0–3:  `UInt32(2)` — SystemProgram Transfer instruction index
    /// - Bytes 4–11: `UInt64` lamports amount
    ///
    /// Account metas:
    /// 1. `from`  — signer, writable (source of lamports)
    /// 2. `to`    — non-signer, writable (destination)
    ///
    /// - Parameters:
    ///   - from: The funding account (must sign).
    ///   - to: The recipient account.
    ///   - lamports: Amount of lamports to transfer.
    /// - Returns: A `TransactionInstruction` targeting the System Program.
    static func transfer(from: PublicKey, to: PublicKey, lamports: UInt64) -> TransactionInstruction {
        var data = Data()

        // Instruction index 2 = Transfer (little-endian UInt32).
        let instructionIndex = UInt32(2).littleEndian
        withUnsafeBytes(of: instructionIndex) { data.append(contentsOf: $0) }

        // Lamports (little-endian UInt64).
        let amount = lamports.littleEndian
        withUnsafeBytes(of: amount) { data.append(contentsOf: $0) }

        let keys: [AccountMeta] = [
            AccountMeta(publicKey: from, isSigner: true,  isWritable: true),
            AccountMeta(publicKey: to,   isSigner: false, isWritable: true),
        ]

        return TransactionInstruction(
            programId: .systemProgramId,
            keys: keys,
            data: data
        )
    }
}
