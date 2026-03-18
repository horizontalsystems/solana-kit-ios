import Foundation

/// Instruction builders and PDA helpers for the Associated Token Account Program
/// (ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL).
///
/// Caseless namespace enum — mirrors the `SolanaSerializer` pattern used throughout this package.
enum AssociatedTokenAccountProgram {

    // MARK: - PDA Derivation

    /// Derives the canonical Associated Token Account (ATA) address for a wallet + mint pair.
    ///
    /// Seeds: `[wallet.data, tokenProgramId.data, mint.data]`
    /// Program: `associatedTokenProgramId`
    ///
    /// Mirrors Android's `PublicKey.associatedTokenAddress(walletAddress:tokenMintAddress:)`.
    ///
    /// - Parameters:
    ///   - wallet: The wallet public key that owns the ATA.
    ///   - mint: The token mint public key.
    /// - Returns: The derived ATA `PublicKey` (bump seed is discarded).
    /// - Throws: `PublicKey.PDAError` if no valid address is found.
    static func associatedTokenAddress(wallet: PublicKey, mint: PublicKey) throws -> PublicKey {
        let seeds: [Data] = [
            wallet.data,
            PublicKey.tokenProgramId.data,
            mint.data,
        ]
        let (address, _) = try PublicKey.findProgramAddress(seeds: seeds, programId: .associatedTokenProgramId)
        return address
    }

    // MARK: - CreateIdempotent

    /// Builds a `CreateIdempotent` instruction for the Associated Token Account Program.
    ///
    /// Unlike the original `Create` (instruction index 0, empty data), `CreateIdempotent`
    /// (instruction index 1) succeeds silently if the ATA already exists — safe to include
    /// unconditionally in any SPL token send flow.
    ///
    /// Instruction data: single byte `0x01` (the `CreateIdempotent` discriminator).
    ///
    /// Account metas:
    /// 1. `payer`            — signer, writable    (pays the rent-exempt reserve)
    /// 2. `associatedToken`  — non-signer, writable (ATA to create)
    /// 3. `owner`            — non-signer, non-writable (wallet that owns the ATA)
    /// 4. `mint`             — non-signer, non-writable
    /// 5. System Program     — non-signer, non-writable
    /// 6. Token Program      — non-signer, non-writable
    /// 7. Sysvar Rent        — non-signer, non-writable
    ///
    /// - Parameters:
    ///   - payer: The fee payer who will fund ATA creation if needed.
    ///   - associatedToken: The ATA address (derived via `associatedTokenAddress(wallet:mint:)`).
    ///   - owner: The wallet that will own the ATA.
    ///   - mint: The token mint.
    /// - Returns: A `TransactionInstruction` targeting the Associated Token Account Program.
    static func createIdempotent(
        payer: PublicKey,
        associatedToken: PublicKey,
        owner: PublicKey,
        mint: PublicKey
    ) -> TransactionInstruction {
        // Instruction index 1 = CreateIdempotent.
        let data = Data([1])

        let keys: [AccountMeta] = [
            AccountMeta(publicKey: payer,                          isSigner: true,  isWritable: true),
            AccountMeta(publicKey: associatedToken,                isSigner: false, isWritable: true),
            AccountMeta(publicKey: owner,                          isSigner: false, isWritable: false),
            AccountMeta(publicKey: mint,                           isSigner: false, isWritable: false),
            AccountMeta(publicKey: .systemProgramId,               isSigner: false, isWritable: false),
            AccountMeta(publicKey: .tokenProgramId,                isSigner: false, isWritable: false),
            AccountMeta(publicKey: .sysvarRentProgramId,           isSigner: false, isWritable: false),
        ]

        return TransactionInstruction(
            programId: .associatedTokenProgramId,
            keys: keys,
            data: data
        )
    }
}
