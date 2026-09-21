# MobileHarness

[![CI](https://github.com/MCTzOCK/MobileHarness/actions/workflows/ci.yml/badge.svg)](https://github.com/MCTzOCK/MobileHarness/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%2026%20%7C%20macOS%2026-blue)](Package.swift)

A mobile AI agent harness for iOS and macOS with **multi-stage tool calling**, **voice calling**, and **usage statistics for cost estimation** — backed by [OpenRouter](https://openrouter.ai) for models and [ElevenLabs](https://elevenlabs.io) for speech.

One agent type, three capabilities:

```swift
import MobileHarness

let agent = Agent(openRouterAPIKey: openRouterKey)

// 1. Tools — the model calls your Swift closures as often as the task needs.
await agent.registerTool(
    "get_weather",
    description: "Returns the current weather for a city.",
    parameters: [.string("city", description: "The city name.")]
) { arguments in
    "22°C, sunny"
}

let response = try await agent.run("What's the weather in Berlin?")
print(response.text)                    // "It's 22°C and sunny in Berlin."
print(response.usage.cost ?? 0)         // this run, all stages, exact Decimal

// 2. Voice — call the agent and hear it answer.
let session = agent.makeVoiceSession(configuration: .init(elevenLabsAPIKey: elevenLabsKey))
try await session.start()               // listen → transcribe → think → speak, in a loop
await session.stop()

// 3. Costs — per-run, per-lifetime, per-model.
let statistics = await agent.statistics
print(statistics.totalCost, statistics.perModel)
```

## Installation

**Xcode:** File ▸ Add Package Dependencies… → `https://github.com/MCTzOCK/MobileHarness.git`

**Package.swift:**

```swift
dependencies: [
    .package(url: "https://github.com/MCTzOCK/MobileHarness.git", from: "0.1.0"),
]
```

Requirements: iOS 26 / macOS 26, Swift 6. No third-party dependencies.

## The API in five minutes

### Agent — `run`, tools, conversation

| What you do | How |
|---|---|
| Run a prompt | `try await agent.run("…")` |
| Register a tool | `await agent.registerTool("name", description: "…", parameters: [.string("arg")]) { args in "result" }` |
| Read tool exchanges | `response.stages` — every call, arguments, and result |
| Watch a run live | `AgentConfiguration(onEvent:)` |
| Keep context | consecutive `run` calls share the conversation; `resetConversation()` clears it |

The agent loop is *multi-stage*: the model's tool requests are executed, results return to the model, and the loop repeats until the model produces a final answer — bounded by `maxToolStages` (default 8). Tool failures are shown to the model instead of failing the run, so it can recover; transport and stage-limit failures throw `HarnessError` and roll the conversation back to a consistent state.

### Voice — call your agent

```swift
let session = agent.makeVoiceSession(configuration: .init(
    elevenLabsAPIKey: key,
    voiceID: "21m00Tcm4TlvDq8ikWAM",     // "Rachel"; list your own via client.listVoices()
    recognitionLanguageCode: "en"        // nil = auto-detect
))
session.onStateChange = { state in       // idle / listening / transcribing / thinking / speaking
    updateCallUI(state)
}
try await session.start()                // ends via session.stop() or session.lastErrorDescription
```

Turn taking is automatic — an `UtteranceDetector` watches microphone energy with hysteresis, silence timeout, and blip filtering, all tunable. For custom flows, compose the primitives: `session.listenOnce()`, `session.ask(_:)`, `session.say(_:)`.

> **Permissions:** your app must add `NSMicrophoneUsageDescription` and request record permission before the first recording. See the [Voice calling guide](Sources/MobileHarness/MobileHarness.docc/VoiceCalling.md).

### Usage statistics — know the spend

Every model turn is metered and every amount is an exact `Decimal`:

```swift
let response = try await agent.run("…")

response.usage                  // this run: prompt/completion/total tokens, cost, source
let stats = await agent.statistics

stats.requestCount              // model turns across the agent's lifetime
stats.totalCost                 // reported + estimated
stats.reportedCost              // what OpenRouter billed exactly
stats.estimatedCost             // local estimate when OpenRouter reported none
stats.averageCostPerRequest
stats.perModel                  // [modelID: ModelUsage]

let keyInfo = try await agent.fetchAPIKeyInfo()   // account-level spend, limits, rate limits
keyInfo.spendingLimitRemaining
```

When OpenRouter omits `usage.cost` (common on free-tier models), the harness estimates from the published per-token pricing table (`CostEstimator`) and marks it `CostSource.estimated` — estimates never mix into reported sums.

## Documentation

Full reference for every public symbol, plus four guides, ship as a DocC catalog in the package:

- **Xcode:** Product ▸ Build Documentation
- **Command line:** `xcodebuild docbuild -scheme MobileHarness -destination 'platform=macOS'`

Guides: [Getting started](Sources/MobileHarness/MobileHarness.docc/GettingStarted.md) · [Tool calling](Sources/MobileHarness/MobileHarness.docc/ToolCalling.md) · [Voice calling](Sources/MobileHarness/MobileHarness.docc/VoiceCalling.md) · [Usage & costs](Sources/MobileHarness/MobileHarness.docc/UsageAndCosts.md)

## Storing API keys

Never ship keys in source, `UserDefaults`, or plists. Use the keychain:

```swift
let store = KeychainAPIKeyStore()
try await store.saveAPIKey(key, for: APIKeyService.openRouter)

let agent = Agent(openRouterAPIKey:
    try await store.loadAPIKey(for: APIKeyService.openRouter) ?? "")
```

Keys are stored device-only (`AfterFirstUnlockThisDeviceOnly`) with add-or-update semantics and full `OSStatus` handling.

## Testing your agent features

All service traffic flows through the `HTTPTransport` protocol. Inject a mock to test agents, voice flows, and cost estimation with no network — exactly what this package's own 60+ tests do:

```swift
let transport = MockTransport(responding: [Fixtures.completion(text: "Hi!")])
let agent = Agent(configuration: .init(openRouterAPIKey: "test", transport: transport))
```

The mock and fixtures above live in the package's test target — copy them into yours, or depend on the target via `@testable import` in a local test package.

## Project layout

```
Sources/MobileHarness/
├── Agent/       Agent actor, tool registry, events, multi-stage loop
├── OpenRouter/  Chat completions, pricing, cost estimation
├── Voice/       ElevenLabs client, microphone recorder, player, call session
├── Usage/       Usage records, statistics, per-model aggregation
└── Support/     HTTP transport, JSON values, errors, keychain key store
```

## Contributing & license

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Released under the [MIT License](LICENSE). Security reports: [SECURITY.md](SECURITY.md).

## Acknowledgements

Built on the public [OpenRouter](https://openrouter.ai/docs) and [ElevenLabs](https://elevenlabs.io/docs) APIs, whose OpenAPI specifications this package's wire types were verified against.
