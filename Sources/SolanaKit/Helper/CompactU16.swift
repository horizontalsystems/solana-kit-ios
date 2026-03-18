import Foundation

/// Solana compact-u16 variable-length integer encoding.
///
/// Each byte stores 7 bits of the value. Bit 7 (0x80) is the continuation flag:
/// if set, more bytes follow. Values in the range 0–65535 encode as 1–3 bytes.
/// This encoding is used for every array-length field in a serialized Solana transaction.
enum CompactU16 {
    /// Encodes `value` (0–65535) as compact-u16 bytes.
    static func encode(_ value: Int) -> Data {
        precondition(value >= 0 && value <= 65535, "CompactU16.encode: value \(value) out of range 0–65535")
        var remaining = value
        var result = Data()
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining > 0 {
                byte |= 0x80  // continuation bit
            }
            result.append(byte)
        } while remaining > 0
        return result
    }

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
}
