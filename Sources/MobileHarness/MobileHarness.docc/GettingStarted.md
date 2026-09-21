# Getting started

@Metadata {
    @PageImage(purpose: card, source: "getting-started", alt: "A smartphone speaking with an AI agent")
    @PageColor(blue)
}

MobileHarness runs conversational AI agents inside your app with **multi-stage tool calling**, **voice calling**, and **usage-based cost tracking**. Models come from [OpenRouter](https://openrouter.ai); speech from [ElevenLabs](https://elevenlabs.io).

## Install

Add the package in Xcode (File ▸ Add Package Dependencies…) or to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/MCTzOCK/MobileHarness.git", from: "0.1.0"),
]
```

The harness needs iOS 26 or macOS 26 and Swift 6.

## Your first agent

Create an ``Agent`` with an OpenRouter API key and run a prompt. That is the whole API for a plain conversation:

```swift
import MobileHarness

let agent = Agent(openRouterAPIKey: openRouterKey)

let response = try await agent.run("Explain tool calling in one sentence.")
print(response.text)
print(response.usage.cost ?? 0)   // USD for this run
```

Follow-up calls to ``Agent/run(_:)`` continue the same conversation, so the agent keeps context:

```swift
let followUp = try await agent.run("Now explain it to a five-year-old.")
```

Call ``Agent/resetConversation()`` to start over.

## Give the agent tools

Tools are Swift closures the model can call. Register one and the agent handles everything in between — sending the schema to the model, decoding arguments, executing your closure, and feeding the result back:

```swift
await agent.registerTool(
    "get_weather",
    description: "Returns the current weather for a city.",
    parameters: [
        .string("city", description: "The city name."),
        .enumeration("unit", values: ["celsius", "fahrenheit"], required: false),
    ]
) { arguments in
    let city = arguments["city"]?.stringValue ?? "unknown"
    return "\(city): 22°C, sunny"
}

let response = try await agent.run("What's the weather in Berlin?")
// The model called get_weather, the agent executed it, and the answer
// reflects the tool result — see response.stages for the full exchange.
```

See <doc:ToolCalling> for multi-stage chains, parallel calls, and error handling.

## Call the agent by voice

Wrap the agent in a ``VoiceSession`` with an ElevenLabs key and start a call — speak, and the agent answers out loud:

```swift
let session = agent.makeVoiceSession(configuration: .init(
    elevenLabsAPIKey: elevenLabsKey
))
session.onStateChange = { state in /* update your call UI */ }
try await session.start()
// … later
await session.stop()
```

Your app needs the `NSMicrophoneUsageDescription` info-plist key and microphone permission; see <doc:VoiceCalling>.

## Watch the spend

Every completion is metered. ``Agent/statistics`` aggregates tokens and cost across the agent's lifetime, separating amounts OpenRouter reported from amounts the harness estimated:

```swift
let statistics = await agent.statistics
print(statistics.totalCost)              // 0.0042
print(statistics.perModel)               // per-model breakdown
let keyInfo = try await agent.fetchAPIKeyInfo()
print(keyInfo.spendingLimitRemaining ?? "unlimited")
```

See <doc:UsageAndCosts> for the full cost-estimation model.

## Where to go next

- <doc:ToolCalling>
- <doc:VoiceCalling>
- <doc:UsageAndCosts>
- ``Agent`` API reference
