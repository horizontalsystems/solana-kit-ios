import Foundation

/// Parses the 82-byte SPL Mint account binary layout returned by `getMultipleAccounts`
/// (base64 encoding).
///
/// Layout (little-endian):
/// - Bytes  0– 3: `mintAuthorityOption` (u32 LE; 0 = None, 1 = Some)
/// - Bytes  4–35: `mintAuthority` (32-byte public key; valid only if option == 1)
/// - Bytes 36–43: `supply` (u64 LE)
/// - Byte     44: `decimals` (u8)
/// - Byte     45: `isInitialized` (bool)
/// - Bytes 46–49: `freezeAuthorityOption` (u32 LE; 0 = None, 1 = Some)
/// - Bytes 50–81: `freezeAuthority` (32-byte public key)
struct SplMintLayout {

    // MARK: - Parsed fields

    /// Base58-encoded mint authority, or `nil` if not set.
    let mintAuthority: String?

    /// Total token supply.
    let supply: UInt64

    /// Number of decimal places.
    let decimals: UInt8

    /// Whether the mint account is initialized.
    let isInitialized: Bool

    /// Base58-encoded freeze authority, or `nil` if not set.
    let freezeAuthority: String?

    // MARK: - NFT detection

    /// `true` when this mint represents the simplest NFT case: decimals == 0,
    /// supply == 1, and mint authority has been permanently disabled.
    /// Advanced Metaplex-based detection is deferred to milestone 3.3.
    var isNft: Bool {
        decimals == 0 && supply == 1 && mintAuthority == nil
    }

    // MARK: - Init

    enum ParseError: Error {
        case dataTooShort(expected: Int, actual: Int)
    }

    /// Parses a raw 82-byte SPL Mint account data blob.
    ///
    /// - Parameter data: The decoded (non-base64) account data bytes.
    /// - Throws: `ParseError.dataTooShort` if `data.count < 82`.
    init(data: Data) throws {
        guard data.count >= 82 else {
            throw ParseError.dataTooShort(expected: 82, actual: data.count)
        }

        // mintAuthorityOption — bytes 0–3
        let mintAuthorityOption: UInt32 = data.readLE(offset: 0)

        // mintAuthority — bytes 4–35
        if mintAuthorityOption == 1 {
            let keyBytes = data[4 ..< 36]
            mintAuthority = Base58.encode(keyBytes)
        } else {
            mintAuthority = nil
        }

        // supply — bytes 36–43
        supply = data.readLE(offset: 36)

        // decimals — byte 44
        decimals = data[44]

        // isInitialized — byte 45
        isInitialized = data[45] != 0

        // freezeAuthorityOption — bytes 46–49
        let freezeAuthorityOption: UInt32 = data.readLE(offset: 46)

        // freezeAuthority — bytes 50–81
        if freezeAuthorityOption == 1 {
            let keyBytes = data[50 ..< 82]
            freezeAuthority = Base58.encode(keyBytes)
        } else {
            freezeAuthority = nil
        }
    }
}

// MARK: - Data helpers

private extension Data {
    /// Reads a little-endian integer of type `T` starting at `offset`.
    func readLE<T: FixedWidthInteger>(offset: Int) -> T {
        let size = MemoryLayout<T>.size
        return subdata(in: offset ..< offset + size).withUnsafeBytes { ptr in
            T(littleEndian: ptr.loadUnaligned(as: T.self))
        }
    }
}
