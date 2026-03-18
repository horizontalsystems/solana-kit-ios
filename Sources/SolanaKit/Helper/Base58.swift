import Foundation

enum Base58 {
    enum Error: Swift.Error {
        case invalidCharacter
    }

    private static let alphabet: [Character] = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    private static let decodingTable: [Character: Int] = {
        var table = [Character: Int](minimumCapacity: 58)
        for (index, char) in alphabet.enumerated() {
            table[char] = index
        }
        return table
    }()

    /// Encodes arbitrary bytes to a Base58 string (standard Bitcoin alphabet, no checksum).
    static func encode(_ data: Data) -> String {
        let bytes = [UInt8](data)

        // Count leading zero bytes — each maps to a leading '1' in output.
        let leadingZeros = bytes.prefix(while: { $0 == 0 }).count

        // Convert from base-256 to base-58. `digits` is stored little-endian
        // (index 0 = least significant base-58 digit).
        var digits = [Int]()

        for byte in bytes {
            var carry = Int(byte)
            for j in 0 ..< digits.count {
                carry += 256 * digits[j]
                digits[j] = carry % 58
                carry /= 58
            }
            while carry > 0 {
                digits.append(carry % 58)
                carry /= 58
            }
        }

        // Build the output string.
        var output = String(repeating: "1", count: leadingZeros)
        for digit in digits.reversed() {
            output.append(alphabet[digit])
        }
        return output
    }

    /// Decodes a Base58 string back to bytes. Throws `Base58.Error.invalidCharacter` on bad input.
    static func decode(_ string: String) throws -> Data {
        // Count leading '1' characters — each maps to a leading 0x00 byte in output.
        let leadingOnes = string.prefix(while: { $0 == "1" }).count

        // Convert from base-58 to base-256. `bytes` is stored little-endian.
        var bytes = [Int]()

        for char in string {
            guard let digit = decodingTable[char] else {
                throw Error.invalidCharacter
            }
            var carry = digit
            for j in 0 ..< bytes.count {
                carry += 58 * bytes[j]
                bytes[j] = carry % 256
                carry /= 256
            }
            while carry > 0 {
                bytes.append(carry % 256)
                carry /= 256
            }
        }

        // Prepend the zero bytes from leading '1's, then append the decoded bytes
        // (reversed from little-endian to big-endian order).
        var result = Data(repeating: 0, count: leadingOnes)
        for byte in bytes.reversed() {
            result.append(UInt8(byte))
        }
        return result
    }
}
