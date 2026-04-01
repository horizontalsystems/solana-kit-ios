import Foundation

/// Configuration for a Solana JSON-RPC endpoint.
///
/// Supports multiple URLs for round-robin key rotation and failover.
/// Mirrors EvmKit `RpcSource.http(urls:auth:)` pattern.
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

    /// JSON-RPC endpoint URLs. Multiple URLs enable round-robin rotation.
    public let urls: [URL]

    /// The Solana network cluster this endpoint serves.
    public let network: Network

    /// How often (in seconds) the `ApiSyncer` should poll for a new block height.
    public let syncInterval: TimeInterval

    /// `true` when this source points to mainnet-beta.
    public var isMainnet: Bool {
        network == .mainnetBeta
    }

    /// First URL — for display and backward compatibility.
    public var url: URL {
        urls[0]
    }

    // MARK: - Init

    public init(name: String, urls: [URL], network: Network, syncInterval: TimeInterval = 30) {
        precondition(!urls.isEmpty, "RpcSource requires at least one URL")
        self.name = name
        self.urls = urls
        self.network = network
        self.syncInterval = syncInterval
    }

    /// Convenience init for single URL (backward compatibility).
    public init(name: String, url: URL, network: Network, syncInterval: TimeInterval = 30) {
        self.init(name: name, urls: [url], network: network, syncInterval: syncInterval)
    }
}

// MARK: - Static factory methods

public extension RpcSource {
    /// Alchemy mainnet-beta with multiple API keys (round-robin rotation).
    static func alchemy(apiKeys: [String]) -> RpcSource {
        let urls = apiKeys.compactMap { URL(string: "https://solana-mainnet.g.alchemy.com/v2/\($0)") }
        return RpcSource(name: "Alchemy", urls: urls, network: .mainnetBeta, syncInterval: 30)
    }

    /// Alchemy mainnet-beta with single API key.
    static func alchemy(apiKey: String) -> RpcSource {
        alchemy(apiKeys: [apiKey])
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
