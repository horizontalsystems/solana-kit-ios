import Foundation

/// Instruction builders for the Solana Compute Budget Program (ComputeBudget111111111111111111111111111111).
///
/// Caseless namespace enum — mirrors the `SystemProgram` / `TokenProgram` pattern used throughout this package.
/// Each static method returns a `TransactionInstruction` ready to be compiled by `SolanaSerializer.compile()`.
enum ComputeBudgetProgram {

    // MARK: - SetComputeUnitLimit

    /// Builds a `SetComputeUnitLimit` instruction.
    ///
    /// Instruction data layout (5 bytes, little-endian):
    /// - Byte 0:    `0x02` — SetComputeUnitLimit discriminator
    /// - Bytes 1–4: `UInt32` compute unit limit (little-endian)
    ///
    /// No account keys required.
    ///
    /// - Parameter units: The maximum number of compute units the transaction may consume.
    /// - Returns: A `TransactionInstruction` targeting the Compute Budget Program.
    static func setComputeUnitLimit(units: UInt32) -> TransactionInstruction {
        var data = Data()

        // Discriminator byte 0x02 = SetComputeUnitLimit.
        data.append(UInt8(0x02))

        // Compute unit limit (little-endian UInt32).
        let leUnits = units.littleEndian
        withUnsafeBytes(of: leUnits) { data.append(contentsOf: $0) }

        return TransactionInstruction(
            programId: .computeBudgetProgramId,
            keys: [],
            data: data
        )
    }

    // MARK: - SetComputeUnitPrice

    /// Builds a `SetComputeUnitPrice` instruction.
    ///
    /// Instruction data layout (9 bytes, little-endian):
    /// - Byte 0:    `0x03` — SetComputeUnitPrice discriminator
    /// - Bytes 1–8: `UInt64` micro-lamports per compute unit (little-endian)
    ///
    /// No account keys required.
    ///
    /// - Parameter microLamports: The price in micro-lamports per compute unit.
    /// - Returns: A `TransactionInstruction` targeting the Compute Budget Program.
    static func setComputeUnitPrice(microLamports: UInt64) -> TransactionInstruction {
        var data = Data()

        // Discriminator byte 0x03 = SetComputeUnitPrice.
        data.append(UInt8(0x03))

        // Micro-lamports per compute unit (little-endian UInt64).
        let lePrice = microLamports.littleEndian
        withUnsafeBytes(of: lePrice) { data.append(contentsOf: $0) }

        return TransactionInstruction(
            programId: .computeBudgetProgramId,
            keys: [],
            data: data
        )
    }
}
