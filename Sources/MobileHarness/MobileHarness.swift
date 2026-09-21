/// A mobile AI agent harness for iOS and macOS, backed by OpenRouter and
/// ElevenLabs.
///
/// MobileHarness runs conversational agents with **multi-stage tool calling**:
/// the model may call your tools across as many rounds as a task needs, with
/// every exchange, token count, and cost tracked along the way. A built-in
/// **voice calling** mode turns any agent into a hands-free voice assistant.
///
/// The two entry points:
///
/// - ``Agent`` — register tools, send prompts, read answers and usage.
/// - ``VoiceSession`` — call an agent with your voice and hear its answers.
///
/// ### Quick start
///
/// ```swift
/// let agent = Agent(openRouterAPIKey: openRouterKey)
///
/// agent.registerTool(
///     "get_weather",
///     description: "Returns the current weather for a city.",
///     parameters: [.string("city", description: "The city name.")]
/// ) { arguments in
///     "22°C, sunny"
/// }
///
/// let response = try await agent.run("What's the weather in Berlin?")
/// print(response.text)
/// print(await agent.statistics.totalCost)
/// ```
///
/// ### Guides
/// - <doc:GettingStarted>
/// - <doc:ToolCalling>
/// - <doc:VoiceCalling>
/// - <doc:UsageAndCosts>
///
/// ### Topics
///
/// #### Agent
/// - ``Agent``
/// - ``AgentConfiguration``
/// - ``AgentResponse``
/// - ``AgentEvent``
/// - ``ToolParameter``
/// - ``ToolResult``
///
/// #### Voice calling
/// - ``VoiceSession``
/// - ``VoiceConfiguration``
/// - ``VoiceCallState``
/// - ``ElevenLabsClient``
/// - ``MicrophoneRecorder``
/// - ``SpeechPlayer``
///
/// #### Usage and costs
/// - ``UsageStatistics``
/// - ``UsageRecord``
/// - ``CostEstimator``
/// - ``ModelPricing``
/// - ``APIKeyInfo``
///
/// #### Infrastructure
/// - ``OpenRouterClient``
/// - ``APIKeyStore``
/// - ``JSONValue``
/// - ``HarnessError``
public enum MobileHarness {}
