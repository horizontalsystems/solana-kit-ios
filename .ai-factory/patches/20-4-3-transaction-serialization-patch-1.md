# Patch: 20-4-3 Transaction Serialization

**Review:** `reviews/20-4-3-transaction-serialization-review-1.md`
**Risk:** Low — all fixes are additive guards; no behavioral changes to the happy path.

---

## Fix 1: Add account count guard in `compile()` to prevent UInt8 overflow trap

**File:** `Sources/SolanaKit/Helper/SolanaSerializer.swift`
**Lines:** 157–169
**Problem:** If more than 255 unique accounts are collected, `UInt8(groupA.count + groupB.count)` (line 161) and `UInt8(idx)` (line 169) will trigger a Swift arithmetic overflow trap, crashing the process. A library should throw a recoverable error, not crash.

**Fix:** Add a guard immediately after assembling `accountKeys` and before the `UInt8` conversions.

**Replace** (lines 157–170):
```swift
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
```

**With:**
```swift
        let accountKeys = groupA + groupB + groupC + groupD

        // Solana wire format uses UInt8 indices — more than 256 accounts is invalid.
        guard accountKeys.count <= 256 else {
            throw SerializerError.invalidTransactionData(
                "Transaction references \(accountKeys.count) unique accounts, maximum is 256"
            )
        }

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
```

---

## Fix 2: Validate signature count matches header in `serialize(signatures:message:)`

**File:** `Sources/SolanaKit/Helper/SolanaSerializer.swift`
**Lines:** 70–75 (error enum) and 299–313 (serialize method)

**Problem:** `serialize(signatures:message:)` validates each signature is 64 bytes but does not check that `signatures.count` matches `message.header.numRequiredSignatures`. A mismatch produces a wire-format transaction that any RPC node will reject, but the error surfaces as a cryptic RPC response rather than a local validation error.

**Fix — Step A:** Add a new error case to `SerializerError`.

**Replace** (lines 70–75):
```swift
    enum SerializerError: Swift.Error {
        case invalidBlockhash(String)
        case invalidSignatureLength(Int)
        case accountIndexOutOfBounds(PublicKey)
        case invalidTransactionData(String)
    }
```

**With:**
```swift
    enum SerializerError: Swift.Error {
        case invalidBlockhash(String)
        case invalidSignatureLength(Int)
        case signatureCountMismatch(expected: Int, got: Int)
        case accountIndexOutOfBounds(PublicKey)
        case invalidTransactionData(String)
    }
```

**Fix — Step B:** Add the guard at the top of the serialize method.

**Replace** (lines 299–313):
```swift
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
```

**With:**
```swift
    static func serialize(signatures: [Data], message: CompiledMessage) throws -> Data {
        let expected = Int(message.header.numRequiredSignatures)
        guard signatures.count == expected else {
            throw SerializerError.signatureCountMismatch(expected: expected, got: signatures.count)
        }

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
```

---

## Fix 3: Update `buildTransaction()` docstring to show single-compile flow

**File:** `Sources/SolanaKit/Helper/SolanaSerializer.swift`
**Lines:** 497–514

**Problem:** The docstring's "typical single-signer flow" example calls `serializeMessage()` then `buildTransaction()`, which compiles the message twice. The docstring should show the efficient pattern using `compile()` once.

**Replace** (lines 497–514):
```swift
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
```

**With:**
```swift
    /// Compiles instructions, wraps them with the provided signatures, and returns
    /// the full transaction wire-format `Data` ready for base64 encoding and broadcast.
    ///
    /// Typical single-signer flow (compiles once):
    /// ```swift
    /// let message      = try SolanaSerializer.compile(feePayer:instructions:recentBlockhash:)
    /// let messageBytes = SolanaSerializer.serialize(message: message)
    /// let signature    = try signer.sign(data: messageBytes)
    /// let txData       = try SolanaSerializer.serialize(signatures: [signature], message: message)
    /// ```
    ///
    /// This convenience method compiles and serializes in one call. If you need
    /// the message bytes for signing first, use `compile()` + `serialize(message:)`
    /// + `serialize(signatures:message:)` directly to avoid compiling twice.
    static func buildTransaction(
        feePayer: PublicKey,
        instructions: [TransactionInstruction],
        recentBlockhash: String,
        signatures: [Data]
    ) throws -> Data {
        let message = try compile(feePayer: feePayer, instructions: instructions, recentBlockhash: recentBlockhash)
        return try serialize(signatures: signatures, message: message)
    }
```

---

## Fix 4: Detect truncated compact-u16 encodings in `CompactU16.decode`

**File:** `Sources/SolanaKit/Helper/CompactU16.swift`
**Lines:** 28–42

**Problem:** If the input data ends mid-encoding (last consumed byte has its continuation bit set), `decode` returns an incorrect value with `bytesRead > 0`. The caller (`readCompactU16()` in the deserializer) has no way to distinguish this from a valid decode, causing silent data corruption when parsing malformed transactions.

**Replace** (lines 28–42):
```swift
    /// Decodes a compact-u16 integer from the start of `data`.
    ///
    /// - Returns: A tuple containing the decoded value and the number of bytes consumed.
    static func decode(_ data: Data) -> (value: Int, bytesRead: Int) {
        precondition(!data.isEmpty, "CompactU16.decode: called with empty data")
        var value = 0
        var bytesRead = 0
        var shift = 0
        for byte in data {
            value |= Int(byte & 0x7F) << shift
            shift += 7
            bytesRead += 1
            if byte & 0x80 == 0 {
                break  // no continuation bit — this was the last byte
            }
        }
        return (value: value, bytesRead: bytesRead)
    }
```

**With:**
```swift
    /// Decodes a compact-u16 integer from the start of `data`.
    ///
    /// - Returns: A tuple containing the decoded value and the number of bytes consumed.
    ///   Returns `(0, 0)` if the encoding is truncated (last byte has continuation bit set).
    static func decode(_ data: Data) -> (value: Int, bytesRead: Int) {
        precondition(!data.isEmpty, "CompactU16.decode: called with empty data")
        var value = 0
        var bytesRead = 0
        var shift = 0
        var lastByte: UInt8 = 0
        for byte in data {
            value |= Int(byte & 0x7F) << shift
            shift += 7
            bytesRead += 1
            lastByte = byte
            if byte & 0x80 == 0 {
                break  // no continuation bit — this was the last byte
            }
        }
        // If the last consumed byte still has the continuation bit set, the
        // encoding was truncated — signal failure so callers can detect it.
        if lastByte & 0x80 != 0 {
            return (value: 0, bytesRead: 0)
        }
        return (value: value, bytesRead: bytesRead)
    }
```
