import Foundation

/// Configuration for a Solana JSON-RPC endpoint.
///
/// Mirrors the Android `RpcSource` sealed class, simplified to a plain struct since
/// Swift does not need the sealed-class indirection.
public struct RpcSource {
    // MARK: - Nested Types

    /// The Solana network cluster.
    public enum Network: String {
        /// Solana mainnet (production).
        case mainnetBeta = "mainnet-beta"
        /// Solana testnet.
        case testnet
        /// Solana devnet.
        case devnet
    }

    // MARK: - Properties

    /// Human-readable provider name (e.g. "Alchemy", "QuickNode").
    public let name: String

    /// The JSON-RPC endpoint URL.
    public let url: URL

    /// The Solana network cluster this endpoint serves.
    public let network: Network

    /// How often (in seconds) the `ApiSyncer` should poll for a new block height.
    public let syncInterval: TimeInterval

    /// `true` when this source points to mainnet-beta.
    public var isMainnet: Bool {
        network == .mainnetBeta
    }

    // MARK: - Init

    public init(name: String, url: URL, network: Network, syncInterval: TimeInterval = 30) {
        self.name = name
        self.url = url
        self.network = network
        self.syncInterval = syncInterval
    }
}

// MARK: - Static factory methods

public extension RpcSource {
    /// Alchemy mainnet-beta endpoint.
    static func alchemy(apiKey: String) -> RpcSource {
        RpcSource(
            name: "Alchemy",
            url: URL(string: "https://solana-mainnet.g.alchemy.com/v2/\(apiKey)")!,
            network: .mainnetBeta,
            syncInterval: 30
        )
    }

    /// QuickNode mainnet-beta endpoint.
    static func quickNode(url: URL) -> RpcSource {
        RpcSource(name: "QuickNode", url: url, network: .mainnetBeta, syncInterval: 30)
    }

    /// Public Solana mainnet-beta endpoint (rate-limited, for development only).
    static func mainnetBeta() -> RpcSource {
        RpcSource(
            name: "Solana Mainnet",
            url: URL(string: "https://api.mainnet-beta.solana.com")!,
            network: .mainnetBeta,
            syncInterval: 30
        )
    }

    /// Public Solana devnet endpoint (for testing).
    static func devnet() -> RpcSource {
        RpcSource(
            name: "Solana Devnet",
            url: URL(string: "https://api.devnet.solana.com")!,
            network: .devnet,
            syncInterval: 30
        )
    }
}
