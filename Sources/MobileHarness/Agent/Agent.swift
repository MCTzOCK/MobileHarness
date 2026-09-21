import Foundation

/// A conversational AI agent with multi-stage tool calling, backed by OpenRouter.
///
/// `Agent` is the harness's main entry point. Register tools, then send
/// prompts; the agent loops the model and your tools as many times as the task
/// requires and returns the final answer together with usage and cost.
///
/// ```swift
/// let agent = Agent(openRouterAPIKey: key, model: "openai/gpt-4o-mini")
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
/// print(response.text)                       // "It's 22°C and sunny in Berlin."
/// print(response.usage.cost ?? 0)            // 0.000123 — this run, all stages
/// print(await agent.statistics.totalCost)     // lifetime spend of this agent
/// ```
///
/// The actor serializes runs: concurrent calls to ``run(_:)`` queue in arrival
/// order, each seeing the conversation produced by the last.
///
/// For hands-free voice interaction, build a ``VoiceSession`` around an agent
/// with ``Agent/makeVoiceSession(configuration:)``.
public actor Agent {
    private let configuration: AgentConfiguration
    private let client: OpenRouterClient
    private var estimator: CostEstimator?
    private var tools: [String: RegisteredTool] = [:]
    private var toolOrder: [String] = []
    private var conversation: [WireMessage] = []
    private var tracker = UsageTracker()

    /// Callers waiting for the active run to finish, in arrival order.
    private var waitingRuns: [CheckedContinuation<Void, Never>] = []
    /// Whether a run is currently executing.
    private var isRunning = false

    /// Creates an agent with the given configuration.
    public init(configuration: AgentConfiguration) {
        self.configuration = configuration
        self.client = OpenRouterClient(
            apiKey: configuration.openRouterAPIKey,
            baseURL: configuration.openRouterBaseURL,
            transport: configuration.transport,
            applicationName: configuration.applicationName,
            applicationURL: configuration.applicationURL
        )
        if configuration.estimateCostsWhenMissing {
            self.estimator = CostEstimator(client: client)
        }
    }

    /// Creates an agent with just a key and a model.
    public init(
        openRouterAPIKey: String,
        model: String = AgentConfiguration.defaultModel,
        systemPrompt: String? = nil
    ) {
        self.init(configuration: AgentConfiguration(
            openRouterAPIKey: openRouterAPIKey,
            model: model,
            systemPrompt: systemPrompt
        ))
    }

    // MARK: - Tools

    /// Registers a tool the agent may call.
    ///
    /// Registering a tool with an existing name replaces it. Tool closures run
    /// concurrently-safely; the agent awaits them between model turns.
    ///
    /// - Parameters:
    ///   - name: The tool name as seen by the model — letters, digits, dashes,
    ///     and underscores, up to 64 characters.
    ///   - description: What the tool does, in a sentence or two; the model
    ///     reads this to decide when to call it.
    ///   - parameters: The tool's arguments; see ``ToolParameter``.
    ///   - execute: Runs the tool with the model-supplied arguments and returns
    ///     its result. Thrown errors are reported to the model as failures —
    ///     they do not abort the run.
    public func registerTool(
        _ name: String,
        description: String,
        parameters: [ToolParameter] = [],
        execute: @escaping @Sendable ([String: JSONValue]) async throws -> ToolResult
    ) {
        tools[name] = RegisteredTool(
            name: name,
            description: description,
            parameters: parameters,
            execute: execute
        )
        if !toolOrder.contains(name) {
            toolOrder.append(name)
        }
    }

    /// Registers a tool whose result is plain text.
    ///
    /// A convenience overload of ``registerTool(_:description:parameters:execute:)``
    /// for tools that answer with a string — the most common case.
    public func registerTool(
        _ name: String,
        description: String,
        parameters: [ToolParameter] = [],
        execute: @escaping @Sendable ([String: JSONValue]) async throws -> String
    ) {
        registerTool(name, description: description, parameters: parameters) { arguments in
            ToolResult.success(try await execute(arguments))
        }
    }

    /// Removes the registered tool with the given name.
    public func removeTool(named name: String) {
        tools.removeValue(forKey: name)
        toolOrder.removeAll { $0 == name }
    }

    /// The names of all registered tools, in registration order.
    public var registeredToolNames: [String] {
        toolOrder
    }

    // MARK: - Running

    /// Sends a prompt and runs the agent until it produces a final answer.
    ///
    /// The prompt extends the agent's conversation history, so follow-up
    /// questions keep their context. The model may request tool calls across
    /// several stages — every requested tool runs, its result returns to the
    /// model, and the loop repeats until the model answers without calling
    /// tools or ``AgentConfiguration/maxToolStages`` is exceeded.
    ///
    /// On failure the conversation rolls back to before this prompt, so a
    /// retried run starts from a consistent state.
    ///
    /// - Returns: The final answer together with every tool stage executed and
    ///   the run's merged usage.
    /// - Throws: ``HarnessError`` when a model turn or transport fails, or when
    ///   the stage limit is exceeded.
    @discardableResult
    public func run(_ prompt: String) async throws -> AgentResponse {
        await waitForRunTurn()
        defer { beginNextRun() }

        guard !configuration.openRouterAPIKey.isEmpty else {
            throw HarnessError.missingAPIKey(service: "OpenRouter")
        }

        let conversationAnchor = conversation.count
        conversation.append(.user(prompt))
        emit(.runStarted)
        do {
            let response = try await runToolLoop()
            emit(.runCompleted(text: response.text))
            return response
        } catch {
            // Roll the conversation back to a consistent pre-prompt state so
            // a retried run does not inherit half-finished tool exchanges.
            conversation.removeLast(conversation.count - conversationAnchor)
            emit(.runFailed(description: String(describing: error)))
            throw error
        }
    }

    /// The model-and-tools loop driving one run.
    private func runToolLoop() async throws -> AgentResponse {
        var stages: [ToolStage] = []
        var runUsage = UsageRecord.zero(model: configuration.model)
        var modelTurn = 0

        while true {
            emit(.modelRequestStarted(stage: modelTurn))
            let response = try await client.complete(
                model: configuration.model,
                messages: effectiveMessages(),
                tools: toolDefinitions(),
                temperature: configuration.temperature,
                maxTokens: configuration.maxTokens
            )
            let usageRecord = await recordUsage(response)
            runUsage = runUsage.adding(usageRecord)
            modelTurn += 1

            let choice = response.choices.first
            let message = choice?.message
            let toolCalls = (message?.toolCalls ?? []).map { call in
                WireToolCall(id: call.id, name: call.function.name, argumentsJSON: call.function.arguments)
            }
            emit(.modelResponseReceived(stage: modelTurn - 1, text: message?.content))

            guard !toolCalls.isEmpty else {
                let text = message?.content ?? ""
                conversation.append(.assistant(content: text))
                return AgentResponse(
                    text: text,
                    model: response.model ?? configuration.model,
                    stages: stages,
                    usage: runUsage,
                    finishReason: choice?.finishReason
                )
            }

            conversation.append(.assistant(content: message?.content, toolCalls: toolCalls))
            if stages.count >= configuration.maxToolStages {
                throw HarnessError.maximumToolStagesExceeded(limit: configuration.maxToolStages)
            }

            var invocations: [ToolInvocation] = []
            for call in toolCalls {
                let arguments = (try? JSONDecoder().decode(
                    [String: JSONValue].self,
                    from: Data(call.argumentsJSON.utf8)
                )) ?? [:]
                emit(.toolExecutionStarted(name: call.name, arguments: arguments))
                let result = await executeTool(call, decodedArguments: arguments)
                emit(.toolExecutionFinished(name: call.name, result: result))
                conversation.append(.tool(toolCallID: call.id, content: result.content))
                invocations.append(ToolInvocation(
                    id: call.id,
                    toolName: call.name,
                    arguments: arguments,
                    result: result
                ))
            }
            stages.append(ToolStage(index: stages.count + 1, invocations: invocations))
        }
    }

    /// Executes one tool call, converting every failure into a model-visible error result.
    private func executeTool(_ call: WireToolCall, decodedArguments: [String: JSONValue]) async -> ToolResult {
        guard let tool = tools[call.name] else {
            let available = toolOrder.isEmpty ? "none are registered" : toolOrder.joined(separator: ", ")
            return .failure("Unknown tool \"\(call.name)\". Available tools: \(available).")
        }
        do {
            return try await tool.execute(decodedArguments)
        } catch {
            return .failure("Tool \"\(call.name)\" failed: \(String(describing: error))")
        }
    }

    /// Records a completion's usage and resolves its cost — reported when
    /// available, estimated otherwise.
    private func recordUsage(_ response: ChatCompletionResponseDTO) async -> UsageRecord {
        let model = response.model ?? configuration.model
        guard let usage = response.usage else {
            let empty = UsageRecord.zero(model: model)
            tracker.record(empty)
            return empty
        }
        let promptTokens = usage.promptTokens ?? 0
        let completionTokens = usage.completionTokens ?? 0
        let totalTokens = usage.totalTokens ?? (promptTokens + completionTokens)

        if let reportedCost = usage.cost {
            let record = UsageRecord(
                model: model,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: totalTokens,
                cost: Decimal(usdDouble: reportedCost),
                costSource: .reported
            )
            tracker.record(record)
            return record
        }

        var estimatedCost: Decimal?
        if let estimator {
            estimatedCost = try? await estimator.estimatedCost(
                model: model,
                promptTokens: promptTokens,
                completionTokens: completionTokens
            )
        }
        let record = UsageRecord(
            model: model,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            cost: estimatedCost,
            costSource: estimatedCost == nil ? nil : .estimated
        )
        tracker.record(record)
        return record
    }

    // MARK: - Conversation

    /// The conversation so far as user, assistant, and tool texts.
    ///
    /// Assistant turns that only request tool calls are omitted.
    public var transcript: [TranscriptEntry] {
        conversation.compactMap { message in
            switch message.kind {
            case let .user(text):
                TranscriptEntry(role: .user, text: text)
            case let .assistant(text, _) where text != nil && !(text?.isEmpty ?? true):
                TranscriptEntry(role: .assistant, text: text ?? "")
            case let .tool(_, content):
                TranscriptEntry(role: .tool, text: content)
            default:
                nil
            }
        }
    }

    /// Clears the conversation history; registered tools and statistics remain.
    public func resetConversation() {
        conversation = []
    }

    // MARK: - Usage statistics

    /// The usage statistics accumulated across every run of this agent.
    ///
    /// - Complexity: O(*m*), where *m* is the number of distinct models used.
    public var statistics: UsageStatistics {
        tracker.statistics
    }

    /// Clears all accumulated usage statistics.
    public func resetStatistics() {
        tracker.reset()
    }

    /// Fetches account-level usage and limits for the configured API key.
    ///
    /// A convenience passthrough to ``OpenRouterClient/fetchAPIKeyInfo()`` for
    /// dashboards that show remaining budget next to ``statistics``.
    public func fetchAPIKeyInfo() async throws -> APIKeyInfo {
        try await client.fetchAPIKeyInfo()
    }

    // MARK: - Voice

    /// Creates a voice call session for this agent using ElevenLabs.
    ///
    /// The session speaks the agent's answers aloud and transcribes what you
    /// say back to it; see ``VoiceSession``.
    /// - Parameter configuration: The voice configuration carrying the
    ///   ElevenLabs API key and voice settings.
    public func makeVoiceSession(configuration: VoiceConfiguration) -> VoiceSession {
        VoiceSession(agent: self, configuration: configuration)
    }

    // MARK: - Run serialization

    /// Suspends until no other run is executing, then claims the run lock.
    private func waitForRunTurn() async {
        if !isRunning {
            isRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            waitingRuns.append(continuation)
        }
    }

    /// Hands the run lock to the next waiting run, or releases it.
    private func beginNextRun() {
        if let next = waitingRuns.first {
            waitingRuns.removeFirst()
            next.resume()
        } else {
            isRunning = false
        }
    }

    // MARK: - Internals

    /// The messages sent to the model: the system prompt plus the conversation.
    private func effectiveMessages() -> [WireMessage] {
        if let systemPrompt = configuration.systemPrompt, !systemPrompt.isEmpty {
            return [.system(systemPrompt)] + conversation
        }
        return conversation
    }

    /// The registered tools' wire definitions, in registration order.
    private func toolDefinitions() -> [ChatCompletionRequestDTO.ToolDefinition] {
        toolOrder.compactMap { tools[$0]?.definition }
    }

    private func emit(_ event: AgentEvent) {
        configuration.onEvent?(event)
    }
}
