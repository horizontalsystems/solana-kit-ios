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

    // MARK: - Parsing

    /// Scans `compiledMessage.instructions` for a `SetComputeUnitLimit` instruction and
    /// returns the encoded compute unit limit, or `nil` if no such instruction is present.
    ///
    /// Discriminator `0x02`: bytes 1–4 are the little-endian `UInt32` limit.
    static func parseComputeUnitLimit(from compiledMessage: SolanaSerializer.CompiledMessage) -> UInt32? {
        for ix in compiledMessage.instructions {
            guard Int(ix.programIdIndex) < compiledMessage.accountKeys.count,
                  compiledMessage.accountKeys[Int(ix.programIdIndex)] == .computeBudgetProgramId,
                  ix.data.count >= 5,
                  ix.data[ix.data.startIndex] == 0x02
            else { continue }

            // The value starts 1 byte after the discriminator — an offset that is (almost) never
            // aligned, so it must be read with the unaligned-safe helper, never `load(as:)`
            // (which traps: "load from misaligned raw pointer"). `readLE`'s offset is in the
            // receiver's own index space, which for a Data slice is the original (absolute) one.
            return ix.data.readLE(offset: ix.data.startIndex + 1)
        }
        return nil
    }

    /// Scans `compiledMessage.instructions` for a `SetComputeUnitPrice` instruction and
    /// returns the encoded micro-lamport price, or `nil` if no such instruction is present.
    ///
    /// Discriminator `0x03`: bytes 1–8 are the little-endian `UInt64` price.
    static func parseComputeUnitPrice(from compiledMessage: SolanaSerializer.CompiledMessage) -> UInt64? {
        for ix in compiledMessage.instructions {
            guard Int(ix.programIdIndex) < compiledMessage.accountKeys.count,
                  compiledMessage.accountKeys[Int(ix.programIdIndex)] == .computeBudgetProgramId,
                  ix.data.count >= 9,
                  ix.data[ix.data.startIndex] == 0x03
            else { continue }

            // Same misalignment hazard as parseComputeUnitLimit above — read via `readLE`.
            return ix.data.readLE(offset: ix.data.startIndex + 1)
        }
        return nil
    }

    /// Calculates the total transaction fee in SOL for a compiled message.
    ///
    /// Formula:
    /// ```
    /// priorityFee  = computeUnitPrice × computeUnitLimit ÷ 1_000_000   (microLamports → lamports)
    /// totalLamports = baseFee + priorityFee
    /// feeSol        = totalLamports ÷ 1_000_000_000
    /// ```
    ///
    /// Uses Solana runtime defaults (0 microLamports price, 200,000 CU limit) when
    /// the corresponding instruction is absent.
    ///
    /// Mirrors Android `VersionedTransaction.calculateFee(baseFeeLamports)`.
    static func calculateFee(from compiledMessage: SolanaSerializer.CompiledMessage, baseFeeLamports: Int64) -> Decimal {
        let baseFee = Decimal(baseFeeLamports)

        // Solana runtime defaults: 0 microLamports price, 200_000 CU limit.
        // Matches sol4k VersionedTransaction which initializes cuPrice=0, cuLimit=200_000
        // before scanning instructions.
        let computeUnitPrice = parseComputeUnitPrice(from: compiledMessage) ?? 0
        let computeUnitLimit = parseComputeUnitLimit(from: compiledMessage) ?? 200_000

        // Priority fee: microLamports × CU ÷ 1_000_000 = lamports
        let priorityFee = Decimal(computeUnitPrice) * Decimal(computeUnitLimit) / Decimal(1_000_000)
        let totalLamports = baseFee + priorityFee
        return totalLamports / Decimal(1_000_000_000)
    }
}
