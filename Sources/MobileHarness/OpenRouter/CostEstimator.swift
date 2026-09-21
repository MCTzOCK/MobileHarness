import Foundation

/// Estimates completion costs from OpenRouter's published per-token model pricing.
///
/// The agent consults the estimator whenever a completion response omits
/// `usage.cost` — common with free-tier models — so ``UsageStatistics`` still
/// carry a cost figure, marked ``CostSource/estimated``. Pricing is fetched
/// once from OpenRouter and cached in memory.
public actor CostEstimator {
    private let client: OpenRouterClient?
    private var pricingByModel: [String: ModelPricing] = [:]

    /// Creates an estimator backed by the given client.
    ///
    /// The client is only needed to fetch pricing from OpenRouter; estimators
    /// used with ``prime(with:)`` alone can omit it.
    public init(client: OpenRouterClient? = nil) {
        self.client = client
    }

    /// Returns the estimated USD cost of a completion.
    ///
    /// - Parameters:
    ///   - model: The model identifier; a `:provider` variant suffix such as
    ///     `:free` falls back to the base model's pricing.
    ///   - promptTokens: The number of prompt (input) tokens.
    ///   - completionTokens: The number of completion (output) tokens.
    /// - Throws: ``HarnessError/invalidResponse(_:)`` when no pricing is
    ///   available for the model.
    public func estimatedCost(model: String, promptTokens: Int, completionTokens: Int) async throws -> Decimal {
        let pricing = try await pricing(for: model)
        return pricing.cost(promptTokens: promptTokens, completionTokens: completionTokens)
    }

    /// Returns the pricing entry for a model, fetching the pricing table on demand.
    public func pricing(for model: String) async throws -> ModelPricing {
        if let exact = pricingByModel[model] {
            return exact
        }
        try await refresh()
        if let exact = pricingByModel[model] {
            return exact
        }
        // Model IDs may carry variant suffixes such as "openai/gpt-4o:free";
        // fall back to the base ID before giving up.
        if let colon = model.firstIndex(of: ":") {
            let base = String(model[..<colon])
            if let fallback = pricingByModel[base] {
                return fallback
            }
        }
        throw HarnessError.invalidResponse("No pricing information is available for model \"\(model)\".")
    }

    /// Reloads the pricing table from OpenRouter.
    public func refresh() async throws {
        guard let client else {
            throw HarnessError.invalidResponse("The estimator has no client to fetch pricing with.")
        }
        let pricing = try await client.fetchModelPricing()
        pricingByModel = Dictionary(uniqueKeysWithValues: pricing.map { ($0.modelID, $0) })
    }

    /// Injects a pricing table without a network call.
    ///
    /// Useful for tests and for offline cost previews with a bundled snapshot
    /// of the pricing data.
    public func prime(with pricing: [ModelPricing]) {
        pricingByModel.merge(Dictionary(uniqueKeysWithValues: pricing.map { ($0.modelID, $0) })) { _, new in new }
    }
}
