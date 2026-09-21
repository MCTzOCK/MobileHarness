# Tool calling

@Metadata {
    @PageImage(purpose: card, source: "tool-calling", alt: "A tool call flowing through an agent loop")
    @PageColor(green)
}

Tools let an agent act — read a sensor, query your backend, run a calculation. The harness turns your closures into JSON Schema for the model, executes the model's requests, and loops until the task is done.

## How a run unfolds

One ``Agent/run(_:)`` call performs as many *model turns* as the task needs:

1. The prompt (plus conversation history and any tool schemas) goes to the model.
2. If the model requests tool calls, the harness executes each one.
3. Every result returns to the model as a tool message.
4. Steps 2–3 repeat until the model answers without calling tools — or ``AgentConfiguration/maxToolStages`` (default 8) is exceeded, which throws ``HarnessError/maximumToolStagesExceeded(limit:)``.

Each round of tool calls is a *stage*; ``AgentResponse/stages`` replays them:

```swift
let response = try await agent.run("Where is Ben and how warm is it there?")
for stage in response.stages {
    for invocation in stage.invocations {
        print(stage.index, invocation.toolName, invocation.arguments, invocation.result.content)
    }
}
```

## Declaring parameters

``ToolParameter`` factories describe each argument and become strict JSON Schema for the model:

```swift
await agent.registerTool(
    "search_flights",
    description: "Searches flights between two airports.",
    parameters: [
        .string("origin", description: "IATA airport code, e.g. \"BER\"."),
        .string("destination", description: "IATA airport code."),
        .enumeration("cabin", values: ["economy", "business"], required: false),
        .integer("passengers", required: false),
        .array("dates", of: .string, description: "ISO dates to search."),
    ]
) { arguments in
    "no flights found"
}
```

Arguments arrive as ``JSONValue`` — read them with the typed accessors:

```swift
let origin = arguments["origin"]?.stringValue ?? ""
let passengers = arguments["passengers"]?.intValue ?? 1
```

## Structured results

String returns suit most tools. For structured data, wrap a `Codable` type or return a ``ToolResult`` to flag failures:

```swift
struct Forecast: Codable {
    let temperatureCelsius: Double
    let condition: String
}

await agent.registerTool("get_forecast", description: "Returns a forecast.") { _ in
    try JSONValue(wrapping: Forecast(temperatureCelsius: 18, condition: "cloudy")).jsonText()
}
```

If your closure throws, the harness does **not** fail the run — the error becomes a failure ``ToolResult`` the model can see and recover from:

```swift
await agent.registerTool("flaky", description: "Sometimes fails.") { _ in
    try doSomethingThatMightThrow()   // the model learns why it failed
}
```

## Parallel calls

A model may request several tools in one turn; the harness executes them in order within the stage and returns every result together.

## Watching a run live

Pass `onEvent` in ``AgentConfiguration`` to observe the loop — useful for progress UI:

```swift
let agent = Agent(configuration: .init(
    openRouterAPIKey: key,
    onEvent: { event in
        if case let .toolExecutionStarted(name, _) = event {
            showSpinner("Running \(name)…")
        }
    }
))
```

## Conversation safety

A run that fails (network error, stage limit) rolls the conversation back to before its prompt, so a retried run starts from a consistent state. Tool failures never trigger this rollback — only the model sees them.
