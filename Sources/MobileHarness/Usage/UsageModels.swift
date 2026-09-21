import Foundation

/// Indicates how the cost of a completion was determined.
public enum CostSource: String, Sendable, Hashable {
    /// OpenRouter reported the exact billed cost in the completion response.
    case reported
    /// The cost was computed locally from OpenRouter's published per-token
    /// model pricing because the response did not include one.
    case estimated
}

/// The token and cost accounting for a single model completion.
///
/// A multi-stage agent run performs one completion per stage; each completion
/// produces its own `UsageRecord`, and ``AgentResponse/usage`` carries the
/// merged total for the whole run.
public struct UsageRecord: Sendable, Hashable {
    /// The identifier of the model that handled the completion, for example `"openai/gpt-4o-mini"`.
    public let model: String
    /// The number of prompt (input) tokens billed.
    public let promptTokens: Int
    /// The number of completion (output) tokens billed.
    public let completionTokens: Int
    /// The total number of tokens billed.
    public let totalTokens: Int
    /// The USD cost of the completion, when known.
    ///
    /// `nil` means the cost is unavailable — OpenRouter did not report one and
    /// estimation was disabled.
    public let cost: Decimal?
    /// How `cost` was determined; `nil` exactly when `cost` is `nil`.
    public let costSource: CostSource?

    /// Creates a usage record.
    public init(
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        cost: Decimal?,
        costSource: CostSource?
    ) {
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cost = cost
        self.costSource = costSource
    }

    /// A record with zero usage for the given model and no cost information.
    public static func zero(model: String) -> UsageRecord {
        UsageRecord(model: model, promptTokens: 0, completionTokens: 0, totalTokens: 0, cost: nil, costSource: nil)
    }

    /// Returns a record that sums this record with another covering the same run.
    public func adding(_ other: UsageRecord) -> UsageRecord {
        var mergedCost: Decimal?
        var mergedSource: CostSource?
        switch (cost, other.cost) {
        case let (lhs?, rhs?):
            mergedCost = lhs + rhs
            mergedSource = (costSource == other.costSource) ? costSource : .estimated
        case let (lhs?, nil):
            mergedCost = lhs
            mergedSource = costSource
        case let (nil, rhs?):
            mergedCost = rhs
            mergedSource = other.costSource
        case (nil, nil):
            mergedCost = nil
        }
        return UsageRecord(
            model: other.model.isEmpty ? model : other.model,
            promptTokens: promptTokens + other.promptTokens,
            completionTokens: completionTokens + other.completionTokens,
            totalTokens: totalTokens + other.totalTokens,
            cost: mergedCost,
            costSource: mergedSource
        )
    }
}

/// Usage totals accumulated for one model.
public struct ModelUsage: Sendable, Hashable {
    /// The model identifier these totals belong to.
    public let model: String
    /// The number of completions accounted.
    public let requestCount: Int
    /// The number of prompt tokens accounted.
    public let promptTokens: Int
    /// The number of completion tokens accounted.
    public let completionTokens: Int
    /// The number of total tokens accounted.
    public let totalTokens: Int
    /// The USD cost OpenRouter reported for these completions.
    public let reportedCost: Decimal
    /// The USD cost estimated locally because it was not reported.
    public let estimatedCost: Decimal

    /// The sum of reported and estimated costs.
    public var totalCost: Decimal { reportedCost + estimatedCost }

    init(model: String) {
        self.model = model
        requestCount = 0
        promptTokens = 0
        completionTokens = 0
        totalTokens = 0
        reportedCost = 0
        estimatedCost = 0
    }

    init(
        model: String,
        requestCount: Int,
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        reportedCost: Decimal,
        estimatedCost: Decimal
    ) {
        self.model = model
        self.requestCount = requestCount
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.reportedCost = reportedCost
        self.estimatedCost = estimatedCost
    }

    func recording(_ record: UsageRecord) -> ModelUsage {
        ModelUsage(
            model: model,
            requestCount: requestCount + 1,
            promptTokens: promptTokens + record.promptTokens,
            completionTokens: completionTokens + record.completionTokens,
            totalTokens: totalTokens + record.totalTokens,
            reportedCost: reportedCost + (record.costSource == .reported ? record.cost ?? 0 : 0),
            estimatedCost: estimatedCost + (record.costSource == .estimated ? record.cost ?? 0 : 0)
        )
    }
}

/// Aggregated usage statistics for cost estimation.
///
/// An ``Agent`` accumulates one of these across every completion it performs;
/// read it any time with ``Agent/statistics``.
///
/// ```swift
/// let stats = await agent.statistics
/// print("Total spend: $\(stats.totalCost)")
/// print("GPT-4o share: \(stats.perModel["openai/gpt-4o"]?.totalCost ?? 0)")
/// ```
public struct UsageStatistics: Sendable, Hashable {
    /// The number of model completions accounted.
    public let requestCount: Int
    /// The number of prompt tokens accounted.
    public let promptTokens: Int
    /// The number of completion tokens accounted.
    public let completionTokens: Int
    /// The number of total tokens accounted.
    public let totalTokens: Int
    /// The USD cost OpenRouter reported, summed.
    public let reportedCost: Decimal
    /// The USD cost estimated locally, summed.
    public let estimatedCost: Decimal
    /// Totals broken down per model, keyed by model identifier.
    public let perModel: [String: ModelUsage]
    /// When the first accounted completion happened, or `nil` when nothing is recorded.
    public let startedAt: Date?
    /// When the most recent accounted completion happened, or `nil` when nothing is recorded.
    public let lastRequestAt: Date?

    /// The sum of reported and estimated costs.
    public var totalCost: Decimal { reportedCost + estimatedCost }

    /// The mean cost per accounted completion.
    ///
    /// Zero when `requestCount` is zero.
    public var averageCostPerRequest: Decimal {
        guard requestCount > 0 else { return 0 }
        return totalCost / Decimal(requestCount)
    }

    init(
        requestCount: Int = 0,
        promptTokens: Int = 0,
        completionTokens: Int = 0,
        totalTokens: Int = 0,
        reportedCost: Decimal = 0,
        estimatedCost: Decimal = 0,
        perModel: [String: ModelUsage] = [:],
        startedAt: Date? = nil,
        lastRequestAt: Date? = nil
    ) {
        self.requestCount = requestCount
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.reportedCost = reportedCost
        self.estimatedCost = estimatedCost
        self.perModel = perModel
        self.startedAt = startedAt
        self.lastRequestAt = lastRequestAt
    }
}

/// The running accumulator behind ``Agent/statistics``.
struct UsageTracker: Sendable {
    private var perModel: [String: ModelUsage] = [:]
    private var startedAt: Date?
    private var lastRequestAt: Date?

    /// Records a completion's usage.
    /// - Parameter date: When the completion finished; defaults to now.
    mutating func record(_ record: UsageRecord, at date: Date = Date()) {
        let model = record.model.isEmpty ? "unknown" : record.model
        perModel[model] = (perModel[model] ?? ModelUsage(model: model)).recording(record)
        if startedAt == nil { startedAt = date }
        lastRequestAt = date
    }

    /// A snapshot of the accumulated statistics.
    var statistics: UsageStatistics {
        let models = Dictionary(uniqueKeysWithValues: perModel.map { ($0.value.model, $0.value) })
        return UsageStatistics(
            requestCount: models.values.reduce(0) { $0 + $1.requestCount },
            promptTokens: models.values.reduce(0) { $0 + $1.promptTokens },
            completionTokens: models.values.reduce(0) { $0 + $1.completionTokens },
            totalTokens: models.values.reduce(0) { $0 + $1.totalTokens },
            reportedCost: models.values.reduce(0) { $0 + $1.reportedCost },
            estimatedCost: models.values.reduce(0) { $0 + $1.estimatedCost },
            perModel: models,
            startedAt: startedAt,
            lastRequestAt: lastRequestAt
        )
    }

    /// Clears all accumulated statistics.
    mutating func reset() {
        perModel = [:]
        startedAt = nil
        lastRequestAt = nil
    }
}
