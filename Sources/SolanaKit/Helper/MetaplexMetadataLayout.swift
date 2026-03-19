import Foundation

/// Parses the Metaplex Metadata Account binary layout (Borsh serialization) returned
/// by `getMultipleAccounts` for metadata PDAs.
///
/// Layout (Borsh, little-endian):
/// ```
/// key:                    u8                           [1]
/// update_authority:       Pubkey                       [32]
/// mint:                   Pubkey                       [32]
/// --- Data ---
/// name:                   u32 length prefix + UTF-8    [4 + len]
/// symbol:                 u32 length prefix + UTF-8    [4 + len]
/// uri:                    u32 length prefix + UTF-8    [4 + len]
/// seller_fee_basis_pts:   u16                          [2]
/// creators:               Option<Vec<Creator>>         [1 + (4 + N*34)?]
/// --- End Data ---
/// primary_sale_happened:  bool                         [1]
/// is_mutable:             bool                         [1]
/// edition_nonce:          Option<u8>                   [1 + 1?]
/// token_standard:         Option<TokenStandard>        [1 + 1?]
/// collection:             Option<Collection>           [1 + 33?]
/// ```
///
/// This is the Swift equivalent of Android's `MetadataAccount` from the Metaplex SDK,
/// reimplemented from the binary spec since there is no Swift Metaplex SDK.
struct MetaplexMetadataLayout {

    // MARK: - Parsed fields

    let key: UInt8
    let updateAuthority: String
    let mint: String
    let name: String
    let symbol: String
    let uri: String
    let tokenStandard: MetaplexTokenStandard?
    let collection: MetaplexCollection?

    // MARK: - Nested types

    /// The Metaplex Token Standard discriminator stored on-chain.
    ///
    /// Raw values match the Borsh-serialized Rust enum order from the Metaplex
    /// Token Metadata program (`mpl-token-metadata`):
    /// ```rust
    /// pub enum TokenStandard {
    ///     NonFungible,                    // 0
    ///     FungibleAsset,                  // 1
    ///     Fungible,                       // 2
    ///     NonFungibleEdition,             // 3
    ///     ProgrammableNonFungible,        // 4
    ///     ProgrammableNonFungibleEdition, // 5
    /// }
    /// ```
    enum MetaplexTokenStandard: UInt8 {
        case nonFungible            = 0
        case fungibleAsset          = 1
        case fungible               = 2
        case nonFungibleEdition     = 3
        case programmableNonFungible = 4
    }

    /// Verified collection info from the on-chain metadata.
    struct MetaplexCollection {
        let verified: Bool
        let key: String // Base58-encoded collection mint address
    }

    // MARK: - Errors

    enum ParseError: Error {
        case dataTooShort
        case invalidStringLength
    }

    // MARK: - Init

    /// Parses a raw Metaplex Metadata Account data blob.
    ///
    /// - Parameter data: The decoded (non-base64) account data bytes.
    /// - Throws: `ParseError.dataTooShort` if the buffer ends unexpectedly.
    init(data: Data) throws {
        var cursor = 0

        // key (1 byte)
        guard data.count > cursor else { throw ParseError.dataTooShort }
        key = data[cursor]
        cursor += 1

        // update_authority (32 bytes)
        guard data.count >= cursor + 32 else { throw ParseError.dataTooShort }
        updateAuthority = Base58.encode(data[cursor ..< cursor + 32])
        cursor += 32

        // mint (32 bytes)
        guard data.count >= cursor + 32 else { throw ParseError.dataTooShort }
        mint = Base58.encode(data[cursor ..< cursor + 32])
        cursor += 32

        // --- Data ---

        // name: u32 length + bytes, trimmed of null bytes
        name = try data.readBorshString(cursor: &cursor)

        // symbol
        symbol = try data.readBorshString(cursor: &cursor)

        // uri
        uri = try data.readBorshString(cursor: &cursor)

        // seller_fee_basis_points (u16) — skip
        guard data.count >= cursor + 2 else { throw ParseError.dataTooShort }
        cursor += 2

        // creators: Option<Vec<Creator>>
        // has_creators (1 byte) + if true: count (u32) + count * 34 bytes each
        guard data.count >= cursor + 1 else { throw ParseError.dataTooShort }
        let hasCreators = data[cursor] != 0
        cursor += 1
        if hasCreators {
            guard data.count >= cursor + 4 else { throw ParseError.dataTooShort }
            let creatorCount = Int(data.readLE(offset: cursor) as UInt32)
            cursor += 4
            // Each Creator: address (32) + verified (1) + share (1) = 34 bytes
            let creatorsSize = creatorCount * 34
            guard data.count >= cursor + creatorsSize else { throw ParseError.dataTooShort }
            cursor += creatorsSize
        }

        // --- End Data ---

        // primary_sale_happened (1 byte) — skip
        guard data.count >= cursor + 1 else { throw ParseError.dataTooShort }
        cursor += 1

        // is_mutable (1 byte) — skip
        guard data.count >= cursor + 1 else { throw ParseError.dataTooShort }
        cursor += 1

        // edition_nonce: Option<u8> → has_nonce (1) + nonce? (0/1)
        guard data.count >= cursor + 1 else { throw ParseError.dataTooShort }
        let hasEditionNonce = data[cursor] != 0
        cursor += 1
        if hasEditionNonce {
            guard data.count >= cursor + 1 else { throw ParseError.dataTooShort }
            cursor += 1
        }

        // token_standard: Option<TokenStandard> → has_token_standard (1) + value? (0/1)
        if data.count < cursor + 1 {
            tokenStandard = nil
        } else {
            let hasTokenStandard = data[cursor] != 0
            cursor += 1
            if hasTokenStandard {
                if data.count >= cursor + 1 {
                    tokenStandard = MetaplexTokenStandard(rawValue: data[cursor])
                    cursor += 1
                } else {
                    tokenStandard = nil
                }
            } else {
                tokenStandard = nil
            }
        }

        // collection: Option<Collection> → has_collection (1) + verified (1) + key (32)
        if data.count < cursor + 1 {
            collection = nil
        } else {
            let hasCollection = data[cursor] != 0
            cursor += 1
            if hasCollection {
                if data.count >= cursor + 33 {
                    let verified = data[cursor] != 0
                    cursor += 1
                    let keyBytes = data[cursor ..< cursor + 32]
                    cursor += 32
                    collection = MetaplexCollection(verified: verified, key: Base58.encode(keyBytes))
                } else {
                    collection = nil
                }
            } else {
                collection = nil
            }
        }
    }
}

// MARK: - Data helpers

private extension Data {
    /// Reads a Borsh-encoded string (u32 length prefix + UTF-8 bytes), trims null bytes,
    /// and advances `cursor` past the consumed bytes.
    func readBorshString(cursor: inout Int) throws -> String {
        guard count >= cursor + 4 else { throw MetaplexMetadataLayout.ParseError.dataTooShort }
        let length = Int(readLE(offset: cursor) as UInt32)
        cursor += 4
        guard count >= cursor + length else { throw MetaplexMetadataLayout.ParseError.dataTooShort }
        let stringData = self[cursor ..< cursor + length]
        cursor += length
        let raw = String(data: stringData, encoding: .utf8) ?? ""
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}
