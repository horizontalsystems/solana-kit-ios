import Foundation

// MARK: - Quote Response

/// Response from the Jupiter v6 `/quote` endpoint.
///
/// Contains the best route found for the given input/output mints and amount.
/// Pass this value directly to `kit.jupiterSwapTransaction(quoteResponse:)` to build
/// the swap transaction.
public struct JupiterQuoteResponse: Codable {
    public let inputMint: String
    public let inAmount: String
    public let outputMint: String
    public let outAmount: String
    public let otherAmountThreshold: String
    public let swapMode: String
    public let slippageBps: Int
    public let priceImpactPct: String
    public let routePlan: [RoutePlan]
    public let contextSlot: Int64?
    public let timeTaken: Double?

    public struct RoutePlan: Codable {
        public let swapInfo: SwapInfo
        public let percent: Int
    }

    public struct SwapInfo: Codable {
        public let ammKey: String
        public let label: String?
        public let inputMint: String
        public let outputMint: String
        public let inAmount: String
        public let outAmount: String
        public let feeAmount: String
        public let feeMint: String
    }
}

// MARK: - Swap Request

/// Request body for the Jupiter v6 `/swap` endpoint.
///
/// Internal type — built by `JupiterApiService.swap()` from a `JupiterQuoteResponse`.
struct JupiterSwapRequest: Encodable {
    let quoteResponse: JupiterQuoteResponse
    let userPublicKey: String
    let wrapAndUnwrapSol: Bool
    let dynamicComputeUnitLimit: Bool
    let dynamicSlippage: Bool?
    let prioritizationFeeLamports: PrioritizationFee?

    struct PrioritizationFee: Encodable {
        let priorityLevelWithMaxLamports: PriorityLevelConfig
    }

    struct PriorityLevelConfig: Encodable {
        let maxLamports: Int64
        let priorityLevel: String
    }
}

// MARK: - Swap Response

/// Response from the Jupiter v6 `/swap` endpoint.
///
/// `swapTransaction` is a base64-encoded V0 versioned transaction that the caller
/// must decode, sign via `Signer`, and broadcast via `kit.sendRawTransaction(rawTransaction:signer:)`.
public struct JupiterSwapResponse: Codable {
    /// Base64-encoded wire-format V0 versioned transaction, ready to be signed and broadcast.
    public let swapTransaction: String
    /// The last valid block height for this transaction — it expires after this block.
    public let lastValidBlockHeight: Int64
    /// Actual prioritization fee in lamports included in the transaction, if any.
    public let prioritizationFeeLamports: Int64?
    /// Compute unit limit set in the transaction's Compute Budget instruction, if any.
    public let computeUnitLimit: Int?
    /// Dynamic slippage report, present when `dynamicSlippage` was requested.
    public let dynamicSlippageReport: DynamicSlippageReport?

    public struct DynamicSlippageReport: Codable {
        public let slippageBps: Int?
        public let otherAmount: String?
        public let simulatedIncurredSlippageBps: Int?
    }
}
