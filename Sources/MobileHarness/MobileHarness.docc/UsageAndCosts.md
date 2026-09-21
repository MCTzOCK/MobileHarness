# Usage and costs

@Metadata {
    @PageImage(purpose: card, source: "usage-and-costs", alt: "A rising cost chart on a phone screen")
    @PageColor(orange)
}

Every model turn the harness performs is metered: tokens, and cost in USD. The numbers flow from OpenRouter's `usage` reporting and stay exact — `Decimal`, never binary floats.

## Per run

``AgentResponse/usage`` merges every model turn of one run:

```swift
let response = try await agent.run("…")
response.usage.promptTokens      // 130 — across all turns
response.usage.completionTokens
response.usage.cost              // Decimal? — USD, nil when unknown
response.usage.costSource        // .reported or .estimated
```

## Lifetime statistics

``Agent/statistics`` aggregates across every run of the agent:

```swift
let statistics = await agent.statistics

statistics.requestCount          // model turns completed
statistics.totalTokens
statistics.totalCost             // reported + estimated
statistics.reportedCost          // OpenRouter's own accounting
statistics.estimatedCost         // local estimation
statistics.averageCostPerRequest
statistics.perModel              // ["openai/gpt-4o-mini": …]
```

Clear it with ``Agent/resetStatistics()``. Statistics survive ``Agent/resetConversation()``.

## Reported vs. estimated

OpenRouter reports the exact billed cost (`usage.cost`) whenever the account is billed for a completion. Some models — notably free-tier ones — report no cost. With ``AgentConfiguration/estimateCostsWhenMissing`` (on by default) the harness then estimates from OpenRouter's published per-token pricing:

```swift
estimator = CostEstimator(client: client)
let cost = try await estimator.estimatedCost(
    model: "openai/gpt-4o-mini",
    promptTokens: 1_000,
    completionTokens: 500
)
```

The estimator fetches the pricing table once and caches it; ``CostSource`` on every record tells you which path produced a given number, and the statistics keep the two sums separate so dashboards never present an estimate as a bill.

## Account-level budget

``Agent/fetchAPIKeyInfo()`` reads what OpenRouter knows about the key itself — spend today, this week, this month, the spending cap, and rate limits:

```swift
let info = try await agent.fetchAPIKeyInfo()
if let remaining = info.spendingLimitRemaining, remaining < 1 {
    warnUser("Less than $1 left on the API budget")
}
```

## A note on rounding

Prices arrive as decimal strings (`"0.00000015"` per token) and costs as doubles. Both convert through the shortest exact decimal representation, so sums like `0.0001 + 0.0002` stay `0.0003` all the way to the UI. Format with `Decimal` APIs — `String(format: "$%.4f", cost as NSDecimalNumber)` or `cost.formatted()`.
