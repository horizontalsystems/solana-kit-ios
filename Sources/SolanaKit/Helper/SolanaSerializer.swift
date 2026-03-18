import Foundation

/// Pure-namespace enum that serializes Solana transactions to wire format.
///
/// Mirrors the EvmKit `enum RLP` pattern — caseless enum used as a static
/// namespace with no instances. Covers the full pipeline:
///
///   1. `compile(feePayer:instructions:recentBlockhash:)` → `CompiledMessage`
///   2. `serialize(message:)` → message bytes (what the signer hashes)
///   3. `serialize(signatures:message:)` → full transaction wire bytes
///   4. `buildTransaction(...)` / `serializeMessage(...)` — convenience wrappers
enum SolanaSerializer {

    // MARK: - Nested types

    struct MessageHeader {
        /// Total number of accounts that must sign (writable-signers + readonly-signers).
        let numRequiredSignatures: UInt8
        /// Number of read-only accounts among the signers.
        let numReadonlySignedAccounts: UInt8
        /// Number of read-only accounts among the non-signers.
        let numReadonlyUnsignedAccounts: UInt8
    }

    struct CompiledInstruction {
        /// Index into `CompiledMessage.accountKeys` for the program being invoked.
        let programIdIndex: UInt8
        /// Indices into `CompiledMessage.accountKeys` for each account meta.
        let accountIndices: [UInt8]
        /// Raw instruction data bytes.
        let data: Data
    }

    struct CompiledMessage {
        let header: MessageHeader
        /// All unique account keys in canonical order:
        /// writable-signers, readonly-signers, writable-non-signers, readonly-non-signers.
        let accountKeys: [PublicKey]
        /// Raw 32-byte blockhash (already decoded from Base58).
        let recentBlockhash: Data
        let instructions: [CompiledInstruction]
    }

    // MARK: - Errors

    enum SerializerError: Swift.Error {
        case invalidBlockhash(String)
        case invalidSignatureLength(Int)
        case accountIndexOutOfBounds(PublicKey)
        case invalidTransactionData(String)
    }

    // MARK: - Compile

    /// Compiles a list of instructions into a `CompiledMessage`.
    ///
    /// Implements the Solana account-key ordering specification:
    /// - Group A: writable signers   (fee payer is always first)
    /// - Group B: readonly signers
    /// - Group C: writable non-signers
    /// - Group D: readonly non-signers
    ///
    /// Header: numRequiredSignatures = |A|+|B|, numReadonlySignedAccounts = |B|,
    ///         numReadonlyUnsignedAccounts = |D|.
    static func compile(
        feePayer: PublicKey,
        instructions: [TransactionInstruction],
        recentBlockhash: String
    ) throws -> CompiledMessage {

        // ── 1. Decode blockhash ───────────────────────────────────────────────
        let blockhashData: Data
        do {
            blockhashData = try Base58.decode(recentBlockhash)
        } catch {
            throw SerializerError.invalidBlockhash(recentBlockhash)
        }
        guard blockhashData.count == 32 else {
            throw SerializerError.invalidBlockhash(recentBlockhash)
        }

        // ── 2. Collect all unique keys + their aggregate flags ────────────────
        // Each key tracks whether it was seen as a signer / writable anywhere.
        var signerSet    = Set<PublicKey>()   // keys that appear as signer
        var writableSet  = Set<PublicKey>()   // keys that appear as writable
        var orderedKeys  = [PublicKey]()      // insertion-order dedup list
        var keySet       = Set<PublicKey>()   // fast membership check

        // Helper: register a key with its flags, preserving first-seen order.
        func register(_ key: PublicKey, isSigner: Bool, isWritable: Bool) {
            if isSigner   { signerSet.insert(key) }
            if isWritable { writableSet.insert(key) }
            if keySet.insert(key).inserted {
                orderedKeys.append(key)
            }
        }

        // Fee payer is always writable + signer and must come first.
        register(feePayer, isSigner: true, isWritable: true)

        for instruction in instructions {
            for meta in instruction.keys {
                register(meta.publicKey, isSigner: meta.isSigner, isWritable: meta.isWritable)
            }
            // Program IDs are non-signer, non-writable (read-only).
            register(instruction.programId, isSigner: false, isWritable: false)
        }

        // ── 3. Partition into four groups (preserving relative insertion order) ─
        var groupA = [PublicKey]()   // writable signers
        var groupB = [PublicKey]()   // readonly signers
        var groupC = [PublicKey]()   // writable non-signers
        var groupD = [PublicKey]()   // readonly non-signers

        for key in orderedKeys {
            let isSigner   = signerSet.contains(key)
            let isWritable = writableSet.contains(key)
            switch (isSigner, isWritable) {
            case (true,  true):  groupA.append(key)
            case (true,  false): groupB.append(key)
            case (false, true):  groupC.append(key)
            case (false, false): groupD.append(key)
            }
        }

        // Fee payer must be the very first key in group A.
        // Because we registered it first, it's already at index 0 — but enforce.
        if let feePayerIdx = groupA.firstIndex(of: feePayer), feePayerIdx != 0 {
            groupA.remove(at: feePayerIdx)
            groupA.insert(feePayer, at: 0)
        }

        let accountKeys = groupA + groupB + groupC + groupD

        // ── 4. Build header ───────────────────────────────────────────────────
        let header = MessageHeader(
            numRequiredSignatures:     UInt8(groupA.count + groupB.count),
            numReadonlySignedAccounts: UInt8(groupB.count),
            numReadonlyUnsignedAccounts: UInt8(groupD.count)
        )

        // ── 5. Build lookup table ─────────────────────────────────────────────
        var keyIndex = [PublicKey: UInt8]()
        for (idx, key) in accountKeys.enumerated() {
            keyIndex[key] = UInt8(idx)
        }

        // ── 6. Compile each instruction ───────────────────────────────────────
        var compiledInstructions = [CompiledInstruction]()
        for instruction in instructions {
            guard let programIdx = keyIndex[instruction.programId] else {
                throw SerializerError.accountIndexOutOfBounds(instruction.programId)
            }
            var accountIndices = [UInt8]()
            for meta in instruction.keys {
                guard let idx = keyIndex[meta.publicKey] else {
                    throw SerializerError.accountIndexOutOfBounds(meta.publicKey)
                }
                accountIndices.append(idx)
            }
            compiledInstructions.append(
                CompiledInstruction(
                    programIdIndex: programIdx,
                    accountIndices: accountIndices,
                    data: instruction.data
                )
            )
        }

        return CompiledMessage(
            header: header,
            accountKeys: accountKeys,
            recentBlockhash: blockhashData,
            instructions: compiledInstructions
        )
    }

    // MARK: - Message serialization

    /// Serializes a `CompiledMessage` to the Solana wire format.
    ///
    /// Layout:
    /// ```
    /// [1]          header.numRequiredSignatures
    /// [1]          header.numReadonlySignedAccounts
    /// [1]          header.numReadonlyUnsignedAccounts
    /// [compact-u16] accountKeys.count
    /// [32 * n]     accountKeys (raw bytes, in order)
    /// [32]         recentBlockhash
    /// [compact-u16] instructions.count
    /// for each instruction:
    ///   [1]          programIdIndex
    ///   [compact-u16] accountIndices.count
    ///   [1 * m]      accountIndices
    ///   [compact-u16] data.count
    ///   [N]          data
    /// ```
    static func serialize(message: CompiledMessage) -> Data {
        var result = Data()

        // Header (3 bytes).
        result.append(message.header.numRequiredSignatures)
        result.append(message.header.numReadonlySignedAccounts)
        result.append(message.header.numReadonlyUnsignedAccounts)

        // Account keys.
        result.append(contentsOf: CompactU16.encode(message.accountKeys.count))
        for key in message.accountKeys {
            result.append(contentsOf: key.data)
        }

        // Recent blockhash (always 32 bytes).
        result.append(contentsOf: message.recentBlockhash)

        // Instructions.
        result.append(contentsOf: CompactU16.encode(message.instructions.count))
        for ix in message.instructions {
            result.append(ix.programIdIndex)
            result.append(contentsOf: CompactU16.encode(ix.accountIndices.count))
            result.append(contentsOf: ix.accountIndices)
            result.append(contentsOf: CompactU16.encode(ix.data.count))
            result.append(contentsOf: ix.data)
        }

        return result
    }

    // MARK: - Transaction serialization

    /// Serializes a fully-signed transaction to the Solana wire format.
    ///
    /// Layout:
    /// ```
    /// [compact-u16]  signatures.count
    /// [64 * n]       signatures (raw Ed25519 bytes)
    /// [message bytes] serialize(message:) output
    /// ```
    ///
    /// - Throws: `SerializerError.invalidSignatureLength` if any signature is not 64 bytes.
    static func serialize(signatures: [Data], message: CompiledMessage) throws -> Data {
        var result = Data()

        result.append(contentsOf: CompactU16.encode(signatures.count))
        for sig in signatures {
            guard sig.count == 64 else {
                throw SerializerError.invalidSignatureLength(sig.count)
            }
            result.append(contentsOf: sig)
        }

        result.append(contentsOf: serialize(message: message))

        return result
    }

    // MARK: - Transaction deserialization

    /// Deserializes a wire-format Solana transaction back into its constituent signatures and compiled message.
    ///
    /// Handles two formats:
    /// - **Legacy** (no version prefix): compact-u16 sig count → signatures → message bytes
    /// - **Versioned v0** (prefix byte `0x80`): same structure, but the message begins with a
    ///   version byte (`0x80`) before the 3-byte header. Any address lookup table data appended
    ///   after the instructions is silently skipped (not needed for fee estimation).
    ///
    /// Detection: after the signatures, if the next byte is `< 0x80` it is the legacy message
    /// `numRequiredSignatures` field. If `>= 0x80` it is a version prefix — consumed and discarded.
    ///
    /// - Parameter transactionData: Raw transaction wire bytes (NOT base64-encoded).
    /// - Returns: A tuple of the parsed signatures and the reconstructed `CompiledMessage`.
    /// - Throws: `SerializerError.invalidTransactionData` on malformed input.
    static func deserialize(transactionData: Data) throws -> (signatures: [Data], message: CompiledMessage) {
        var cursor = transactionData.startIndex

        // Helper: copy `count` bytes into a fresh Data value and advance cursor.
        func read(_ count: Int) throws -> Data {
            let end = cursor + count
            guard end <= transactionData.endIndex else {
                throw SerializerError.invalidTransactionData(
                    "Unexpected end of data at offset \(cursor - transactionData.startIndex), needed \(count) bytes"
                )
            }
            let slice = Data(transactionData[cursor..<end])
            cursor = end
            return slice
        }

        // Helper: decode a compact-u16 value and advance cursor.
        func readCompactU16() throws -> Int {
            guard cursor < transactionData.endIndex else {
                throw SerializerError.invalidTransactionData(
                    "Unexpected end of data reading compact-u16 at offset \(cursor - transactionData.startIndex)"
                )
            }
            let (value, bytesRead) = CompactU16.decode(transactionData[cursor...])
            guard bytesRead > 0 else {
                throw SerializerError.invalidTransactionData(
                    "Failed to decode compact-u16 at offset \(cursor - transactionData.startIndex)"
                )
            }
            cursor += bytesRead
            return value
        }

        // ── 1. Signature count (compact-u16) ──────────────────────────────────
        let sigCount = try readCompactU16()

        // ── 2. Signatures (64 bytes each) ─────────────────────────────────────
        var signatures = [Data]()
        signatures.reserveCapacity(sigCount)
        for _ in 0..<sigCount {
            signatures.append(try read(64))
        }

        // ── 3. Detect message version ──────────────────────────────────────────
        // After the signatures the next byte is either:
        //   • numRequiredSignatures (< 0x80) → legacy message; do NOT consume it.
        //   • A version prefix (>= 0x80)     → versioned message; consume and discard.
        guard cursor < transactionData.endIndex else {
            throw SerializerError.invalidTransactionData("No message data after signatures")
        }
        if transactionData[cursor] >= 0x80 {
            cursor += 1  // skip version byte
        }

        // ── 4. Message header (3 bytes) ────────────────────────────────────────
        let headerData = try read(3)
        let header = MessageHeader(
            numRequiredSignatures:       headerData[headerData.startIndex],
            numReadonlySignedAccounts:   headerData[headerData.startIndex + 1],
            numReadonlyUnsignedAccounts: headerData[headerData.startIndex + 2]
        )

        // ── 5. Account keys ────────────────────────────────────────────────────
        let keyCount = try readCompactU16()
        var accountKeys = [PublicKey]()
        accountKeys.reserveCapacity(keyCount)
        for _ in 0..<keyCount {
            let keyData = try read(32)
            do {
                accountKeys.append(try PublicKey(data: keyData))
            } catch {
                throw SerializerError.invalidTransactionData(
                    "Invalid public key at offset \(cursor - transactionData.startIndex - 32)"
                )
            }
        }

        // ── 6. Recent blockhash (32 bytes) ────────────────────────────────────
        let recentBlockhash = try read(32)

        // ── 7. Instructions ───────────────────────────────────────────────────
        let ixCount = try readCompactU16()
        var instructions = [CompiledInstruction]()
        instructions.reserveCapacity(ixCount)
        for _ in 0..<ixCount {
            // Program ID index (1 byte).
            let programIdIndex = try read(1)[0]

            // Account indices.
            let acctCount = try readCompactU16()
            let acctData  = try read(acctCount)
            let accountIndices = [UInt8](acctData)

            // Instruction data.
            let dataLen = try readCompactU16()
            let ixData  = try read(dataLen)

            instructions.append(CompiledInstruction(
                programIdIndex: programIdIndex,
                accountIndices: accountIndices,
                data: ixData
            ))
        }

        // For versioned v0 transactions additional address lookup table entries may follow.
        // They are not needed for fee estimation so we silently skip them.

        let compiledMessage = CompiledMessage(
            header: header,
            accountKeys: accountKeys,
            recentBlockhash: recentBlockhash,
            instructions: instructions
        )

        return (signatures: signatures, message: compiledMessage)
    }

    // MARK: - Convenience methods

    /// Compiles instructions into a signable message and returns the raw message bytes.
    ///
    /// The caller passes these bytes to `Signer.sign(data:)`, then hands the
    /// resulting signature back to `buildTransaction(...)` to produce the final
    /// wire-format transaction.
    static func serializeMessage(
        feePayer: PublicKey,
        instructions: [TransactionInstruction],
        recentBlockhash: String
    ) throws -> Data {
        let message = try compile(feePayer: feePayer, instructions: instructions, recentBlockhash: recentBlockhash)
        return serialize(message: message)
    }

    /// Compiles instructions, wraps them with the provided signatures, and returns
    /// the full transaction wire-format `Data` ready for base64 encoding and broadcast.
    ///
    /// Typical single-signer flow:
    /// ```swift
    /// let messageBytes = try SolanaSerializer.serializeMessage(feePayer:instructions:recentBlockhash:)
    /// let signature    = try signer.sign(data: messageBytes)
    /// let txData       = try SolanaSerializer.buildTransaction(feePayer:instructions:recentBlockhash:signatures:[signature])
    /// ```
    static func buildTransaction(
        feePayer: PublicKey,
        instructions: [TransactionInstruction],
        recentBlockhash: String,
        signatures: [Data]
    ) throws -> Data {
        let message = try compile(feePayer: feePayer, instructions: instructions, recentBlockhash: recentBlockhash)
        return try serialize(signatures: signatures, message: message)
    }
}
