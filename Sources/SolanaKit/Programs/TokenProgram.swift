import Foundation

/// Instruction builders for the Solana SPL Token Program (TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA).
///
/// Caseless namespace enum — mirrors the `SolanaSerializer` pattern used throughout this package.
/// Each static method returns a `TransactionInstruction` ready to be compiled by `SolanaSerializer.compile()`.
enum TokenProgram {

    // MARK: - Transfer

    /// Builds a basic SPL Token transfer instruction.
    ///
    /// Instruction data layout (9 bytes, little-endian):
    /// - Byte 0:    `UInt8(3)` — SPL Token Transfer instruction index
    /// - Bytes 1–8: `UInt64` amount (raw token units, not UI-adjusted)
    ///
    /// Account metas:
    /// 1. `source`      — non-signer, writable
    /// 2. `destination` — non-signer, writable
    /// 3. `authority`   — signer, non-writable (owner or delegate of source account)
    ///
    /// - Parameters:
    ///   - source: The source token account.
    ///   - destination: The destination token account.
    ///   - authority: The account authorising the transfer (must sign).
    ///   - amount: Raw token amount to transfer.
    /// - Returns: A `TransactionInstruction` targeting the SPL Token Program.
    static func transfer(
        source: PublicKey,
        destination: PublicKey,
        authority: PublicKey,
        amount: UInt64
    ) -> TransactionInstruction {
        var data = Data()

        // Instruction index 3 = Transfer.
        data.append(UInt8(3))

        // Amount (little-endian UInt64).
        let rawAmount = amount.littleEndian
        withUnsafeBytes(of: rawAmount) { data.append(contentsOf: $0) }

        let keys: [AccountMeta] = [
            AccountMeta(publicKey: source,      isSigner: false, isWritable: true),
            AccountMeta(publicKey: destination, isSigner: false, isWritable: true),
            AccountMeta(publicKey: authority,   isSigner: true,  isWritable: false),
        ]

        return TransactionInstruction(
            programId: .tokenProgramId,
            keys: keys,
            data: data
        )
    }

    // MARK: - TransferChecked

    /// Builds an SPL Token TransferChecked instruction.
    ///
    /// `TransferChecked` is the preferred transfer variant because it also validates the
    /// token mint and decimal precision, preventing accidental mismatches.
    ///
    /// Instruction data layout (10 bytes, little-endian):
    /// - Byte 0:    `UInt8(12)` — SPL Token TransferChecked instruction index
    /// - Bytes 1–8: `UInt64` amount (raw token units)
    /// - Byte 9:    `UInt8` decimals
    ///
    /// Account metas:
    /// 1. `source`      — non-signer, writable
    /// 2. `mint`        — non-signer, non-writable
    /// 3. `destination` — non-signer, writable
    /// 4. `authority`   — signer, non-writable
    ///
    /// - Parameters:
    ///   - source: The source token account.
    ///   - mint: The token mint account (used for validation).
    ///   - destination: The destination token account.
    ///   - authority: The account authorising the transfer (must sign).
    ///   - amount: Raw token amount to transfer.
    ///   - decimals: Decimal precision of the token mint (used for validation).
    /// - Returns: A `TransactionInstruction` targeting the SPL Token Program.
    static func transferChecked(
        source: PublicKey,
        mint: PublicKey,
        destination: PublicKey,
        authority: PublicKey,
        amount: UInt64,
        decimals: UInt8
    ) -> TransactionInstruction {
        var data = Data()

        // Instruction index 12 = TransferChecked.
        data.append(UInt8(12))

        // Amount (little-endian UInt64).
        let rawAmount = amount.littleEndian
        withUnsafeBytes(of: rawAmount) { data.append(contentsOf: $0) }

        // Decimals.
        data.append(decimals)

        let keys: [AccountMeta] = [
            AccountMeta(publicKey: source,      isSigner: false, isWritable: true),
            AccountMeta(publicKey: mint,        isSigner: false, isWritable: false),
            AccountMeta(publicKey: destination, isSigner: false, isWritable: true),
            AccountMeta(publicKey: authority,   isSigner: true,  isWritable: false),
        ]

        return TransactionInstruction(
            programId: .tokenProgramId,
            keys: keys,
            data: data
        )
    }
}
