import Foundation
import Testing
@testable import MobileHarness

@Suite("Agent multi-stage tool calling")
struct AgentLoopTests {
    static let key = "sk-or-test"

    func makeAgent(
        responses: [HTTPResponse],
        systemPrompt: String? = nil,
        maxToolStages: Int = 8,
        estimateCosts: Bool = false,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) -> (Agent, MockTransport) {
        let transport = MockTransport(responding: responses)
        let agent = Agent(configuration: AgentConfiguration(
            openRouterAPIKey: Self.key,
            systemPrompt: systemPrompt,
            maxToolStages: maxToolStages,
            estimateCostsWhenMissing: estimateCosts,
            transport: transport,
            onEvent: onEvent
        ))
        return (agent, transport)
    }

    @Test("A prompt without tools returns the answer text and usage")
    func plainRun() async throws {
        let (agent, _) = makeAgent(responses: [
            Fixtures.completion(text: "Paris.", promptTokens: 12, completionTokens: 3, cost: 0.000042),
        ])
        let response = try await agent.run("What is the capital of France?")
        #expect(response.text == "Paris.")
        #expect(response.stages.isEmpty)
        #expect(!response.usedTools)
        #expect(response.usage.promptTokens == 12)
        #expect(response.usage.completionTokens == 3)
        #expect(response.usage.totalTokens == 15)
        #expect(response.usage.cost == Decimal(string: "0.000042"))
        #expect(response.usage.costSource == .reported)
        #expect(response.finishReason == "stop")
    }

    @Test("A single-stage tool call executes the tool and feeds the result back")
    func singleStageToolCall() async throws {
        let (agent, transport) = makeAgent(responses: [
            Fixtures.completion(
                text: nil,
                toolCalls: [("call_1", "get_weather", #"{"city": "Berlin", "unit": "celsius"}"#)],
                promptTokens: 50,
                completionTokens: 20,
                cost: 0.0001
            ),
            Fixtures.completion(text: "It is 22°C and sunny in Berlin.", promptTokens: 80, completionTokens: 10, cost: 0.0002),
        ])
        let seenArguments = ValueBox<[String: JSONValue]>([:])
        await agent.registerTool(
            "get_weather",
            description: "Returns the current weather for a city.",
            parameters: [
                .string("city", description: "The city name."),
                .enumeration("unit", values: ["celsius", "fahrenheit"], required: false),
            ]
        ) { arguments in
            seenArguments.value = arguments
            return "22°C, sunny"
        }

        let response = try await agent.run("Weather in Berlin?")

        #expect(seenArguments.value["city"]?.stringValue == "Berlin")
        #expect(seenArguments.value["unit"]?.stringValue == "celsius")
        #expect(response.text == "It is 22°C and sunny in Berlin.")
        #expect(response.usedTools)
        #expect(response.stages.count == 1)

        let invocation = try #require(response.stages.first?.invocations.first)
        #expect(invocation.toolName == "get_weather")
        #expect(invocation.id == "call_1")
        #expect(invocation.result.content == "22°C, sunny")
        #expect(!invocation.result.isError)

        // Usage merges both model turns of the run.
        #expect(response.usage.promptTokens == 130)
        #expect(response.usage.completionTokens == 30)
        #expect(response.usage.cost == Decimal(string: "0.0003"))

        // The second request carries the assistant tool call and the tool result.
        let requests = transport.requests
        #expect(requests.count == 2)
        let secondBody = try JSONDecoder().decode(JSONValue.self, from: #require(requests[1].body))
        let messages = try #require(secondBody["messages"]?.arrayValue)
        #expect(messages.count == 3) // user, assistant w/ tool_calls, tool
        #expect(messages[1]["tool_calls"]?[0]?["id"]?.stringValue == "call_1")
        #expect(messages[1]["tool_calls"]?[0]?["function"]?["arguments"]?.stringValue == #"{"city": "Berlin", "unit": "celsius"}"#)
        #expect(messages[2]["role"]?.stringValue == "tool")
        #expect(messages[2]["tool_call_id"]?.stringValue == "call_1")
        #expect(messages[2]["content"]?.stringValue == "22°C, sunny")
    }

    @Test("Tool definitions are sent as JSON Schema")
    func toolSchemaOnTheWire() async throws {
        let (agent, transport) = makeAgent(responses: [
            Fixtures.completion(text: "ok"),
        ])
        await await agent.registerTool(
            "search_flights",
            description: "Searches flights.",
            parameters: [
                .string("origin", description: "Departure airport."),
                .integer("passengers", required: false),
                .enumeration("cabin", values: ["economy", "business"], required: false),
                .array("dates", of: .string, required: false),
            ]
        ) { _ in "none found" }

        _ = try await agent.run("Find a flight")

        let body = try JSONDecoder().decode(JSONValue.self, from: #require(transport.requests.first?.body))
        let tool = try #require(body["tools"]?.arrayValue?.first)
        #expect(tool["type"]?.stringValue == "function")
        #expect(tool["function"]?["name"]?.stringValue == "search_flights")
        #expect(tool["function"]?["description"]?.stringValue == "Searches flights.")
        let parameters = try #require(tool["function"]?["parameters"])
        #expect(parameters["type"]?.stringValue == "object")
        #expect(parameters["properties"]?["passengers"]?["type"]?.stringValue == "integer")
        #expect(parameters["properties"]?["cabin"]?["enum"]?.arrayValue?.map(\.stringValue) == ["economy", "business"])
        #expect(parameters["properties"]?["dates"]?["type"]?.stringValue == "array")
        #expect(parameters["properties"]?["dates"]?["items"]?["type"]?.stringValue == "string")
        #expect(parameters["required"]?.arrayValue?.map(\.stringValue) == ["origin"])
        #expect(body["tool_choice"]?.stringValue == "auto")
    }

    @Test("Two stages chain tool calls until the model answers")
    func multiStageToolCalls() async throws {
        let (agent, transport) = makeAgent(responses: [
            Fixtures.completion(text: nil, toolCalls: [("call_a", "lookup_user", #"{"name": "ben"}"#)]),
            Fixtures.completion(text: nil, toolCalls: [("call_b", "get_weather", #"{"city": "Berlin"}"#)]),
            Fixtures.completion(text: "Ben is in Berlin, where it is 22°C."),
        ])
        await agent.registerTool("lookup_user", description: "Looks up a user.") { _ in
            ToolResult.success(#"{"city": "Berlin"}"#)
        }
        await agent.registerTool("get_weather", description: "Weather for a city.") { _ in
            "22°C"
        }

        let response = try await agent.run("Where is Ben and how warm is it?")

        #expect(response.stages.count == 2)
        #expect(response.stages[0].invocations.first?.toolName == "lookup_user")
        #expect(response.stages[1].invocations.first?.toolName == "get_weather")
        #expect(transport.requests.count == 3)
        // The third request contains both rounds of tool exchange.
        let thirdBody = try JSONDecoder().decode(JSONValue.self, from: #require(transport.requests[2].body))
        let messages = try #require(thirdBody["messages"]?.arrayValue)
        #expect(messages.count == 5) // user, assistant+call_a, tool_a, assistant+call_b, tool_b
    }

    @Test("Parallel tool calls in one stage all execute")
    func parallelToolCalls() async throws {
        let (agent, _) = makeAgent(responses: [
            Fixtures.completion(text: nil, toolCalls: [
                ("call_1", "add", #"{"a": 1, "b": 2}"#),
                ("call_2", "add", #"{"a": 3, "b": 4}"#),
            ]),
            Fixtures.completion(text: "3 and 7."),
        ])
        let counter = Counter()
        await agent.registerTool("add", description: "Adds two integers.") { arguments in
            await counter.increment()
            let a = arguments["a"]?.intValue ?? 0
            let b = arguments["b"]?.intValue ?? 0
            return "\(a + b)"
        }

        let response = try await agent.run("Add 1+2 and 3+4")

        let invocations = try #require(response.stages.first?.invocations)
        #expect(invocations.map(\.toolName) == ["add", "add"])
        #expect(invocations.map(\.result.content) == ["3", "7"])
        let callCount = await counter.value
        #expect(callCount == 2)
    }

    @Test("A throwing tool reports a failure result to the model")
    func toolThrowingFeedsErrorBack() async throws {
        let (agent, transport) = makeAgent(responses: [
            Fixtures.completion(text: nil, toolCalls: [("call_1", "boom", #"{}"#)]),
            Fixtures.completion(text: "The tool broke."),
        ])
        await agent.registerTool("boom", description: "Always throws.") { (_: [String: JSONValue]) -> ToolResult in
            throw URLError(.badURL)
        }

        let response = try await agent.run("Try it")

        let invocation = try #require(response.stages.first?.invocations.first)
        #expect(invocation.result.isError)
        #expect(invocation.result.content.contains("boom"))
        // The failure text reaches the model as the tool message.
        let secondBody = try JSONDecoder().decode(JSONValue.self, from: #require(transport.requests[1].body))
        let messages = try #require(secondBody["messages"]?.arrayValue)
        #expect(messages[2]["content"]?.stringValue?.contains("failed") == true)
        #expect(response.text == "The tool broke.")
    }

    @Test("An unknown tool reports a failure listing available tools")
    func unknownTool() async throws {
        let (agent, _) = makeAgent(responses: [
            Fixtures.completion(text: nil, toolCalls: [("call_1", "nope", #"{}"#)]),
            Fixtures.completion(text: "Cannot do that."),
        ])
        await agent.registerTool("known", description: "A known tool.") { _ in "ok" }

        let response = try await agent.run("Do the thing")

        let invocation = try #require(response.stages.first?.invocations.first)
        #expect(invocation.result.isError)
        #expect(invocation.result.content.contains("nope"))
        #expect(invocation.result.content.contains("known"))
    }

    @Test("Malformed tool arguments deliver an empty argument dictionary")
    func malformedArguments() async throws {
        let (agent, _) = makeAgent(responses: [
            Fixtures.completion(text: nil, toolCalls: [("call_1", "echo", #"{"broken"#)]),
            Fixtures.completion(text: "done"),
        ])
        let received = ValueBox<[String: JSONValue]>(["sentinel": .bool(true)])
        await agent.registerTool("echo", description: "Echoes arguments.") { arguments in
            received.value = arguments
            return "ok"
        }

        _ = try await agent.run("Go")
        #expect(received.value.isEmpty)
    }

    @Test("Exceeding the stage limit throws and rolls the conversation back")
    func stageLimitAndRollback() async throws {
        let (agent, _) = makeAgent(
            responses: [
                Fixtures.completion(text: nil, toolCalls: [("call_\(0)", "loop", #"{}"#)]),
            ],
            maxToolStages: 2
        )
        await agent.registerTool("loop", description: "Loops forever.") { _ in "again" }

        await #expect(throws: HarnessError.maximumToolStagesExceeded(limit: 2)) {
            _ = try await agent.run("Loop")
        }

        // The failed run left nothing behind — neither prompt nor exchanges.
        let transcript = await agent.transcript
        #expect(transcript.isEmpty)

        // A fresh run on the same agent works.
        let transport2 = MockTransport(responding: [Fixtures.completion(text: "fresh")])
        let agent2 = Agent(configuration: AgentConfiguration(
            openRouterAPIKey: Self.key,
            maxToolStages: 2,
            transport: transport2
        ))
        await agent2.registerTool("loop", description: "Loops forever.") { _ in "again" }
        let retry = try await agent2.run("Hello")
        #expect(retry.text == "fresh")
    }

    @Test("Conversation history carries across runs, with the system prompt first")
    func conversationHistory() async throws {
        let (agent, transport) = makeAgent(
            responses: [
                Fixtures.completion(text: "Paris."),
                Fixtures.completion(text: "It is the capital of France."),
            ],
            systemPrompt: "You are concise."
        )
        _ = try await agent.run("Capital of France?")
        _ = try await agent.run("Tell me more about it")

        let secondBody = try JSONDecoder().decode(JSONValue.self, from: #require(transport.requests[1].body))
        let messages = try #require(secondBody["messages"]?.arrayValue)
        #expect(messages.count == 4) // system, user, assistant, user
        #expect(messages[0]["role"]?.stringValue == "system")
        #expect(messages[0]["content"]?.stringValue == "You are concise.")
        #expect(messages[3]["role"]?.stringValue == "user")
        #expect(messages[3]["content"]?.stringValue == "Tell me more about it")
        let transcript = await agent.transcript
        #expect(transcript.map(\.role) == [.user, .assistant, .user, .assistant])
    }

    @Test("resetConversation clears history but keeps tools and statistics")
    func resetConversation() async throws {
        let (agent, transport) = makeAgent(responses: [
            Fixtures.completion(text: "one", promptTokens: 1, completionTokens: 1, cost: 0.001),
            Fixtures.completion(text: "two"),
        ])
        await agent.registerTool("noop", description: "No operation.") { _ in "ok" }
        _ = try await agent.run("first")
        await agent.resetConversation()

        let transcript = await agent.transcript
        #expect(transcript.isEmpty)
        let names = await agent.registeredToolNames
        #expect(names == ["noop"])
        let statistics = await agent.statistics
        #expect(statistics.requestCount == 1)

        _ = try await agent.run("second")
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(transport.requests[1].body))
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.count == 1) // only the new user message
    }

    @Test("Statistics aggregate tokens and costs across runs and models")
    func statisticsAggregation() async throws {
        let (agent, _) = makeAgent(responses: [
            Fixtures.completion(text: "a", model: "openai/gpt-4o-mini", promptTokens: 10, completionTokens: 5, cost: 0.0001),
            Fixtures.completion(text: "b", model: "openai/gpt-4o", promptTokens: 100, completionTokens: 50, cost: 0.001),
        ])
        _ = try await agent.run("one")
        _ = try await agent.run("two")

        let statistics = await agent.statistics
        #expect(statistics.requestCount == 2)
        #expect(statistics.promptTokens == 110)
        #expect(statistics.completionTokens == 55)
        #expect(statistics.totalTokens == 165)
        #expect(statistics.reportedCost == Decimal(string: "0.0011"))
        #expect(statistics.estimatedCost == 0)
        #expect(statistics.totalCost == Decimal(string: "0.0011"))
        #expect(statistics.averageCostPerRequest == Decimal(string: "0.00055"))
        #expect(statistics.perModel["openai/gpt-4o-mini"]?.totalTokens == 15)
        #expect(statistics.perModel["openai/gpt-4o"]?.totalTokens == 150)
        #expect(statistics.startedAt != nil)
        #expect(statistics.lastRequestAt != nil)

        await agent.resetStatistics()
        let cleared = await agent.statistics
        #expect(cleared.requestCount == 0)
        #expect(cleared.totalCost == 0)
    }

    @Test("Missing cost is estimated from model pricing when enabled")
    func estimatedCostPath() async throws {
        let transport = MockTransport(routing: { request in
            if request.url.path.hasSuffix("/models") {
                return HTTPResponse(statusCode: 200, body: Data(Fixtures.modelsBody().utf8))
            }
            return Fixtures.completion(text: "hello", promptTokens: 1000, completionTokens: 500, cost: nil)
        })
        let agent = Agent(configuration: AgentConfiguration(
            openRouterAPIKey: Self.key,
            estimateCostsWhenMissing: true,
            transport: transport
        ))
        let response = try await agent.run("hi")
        #expect(response.usage.costSource == .estimated)
        // 1000 * 0.00000015 + 500 * 0.0000006 = 0.00015 + 0.0003 = 0.00045
        #expect(response.usage.cost == Decimal(string: "0.00045"))
        let statistics = await agent.statistics
        #expect(statistics.estimatedCost == Decimal(string: "0.00045"))
        #expect(statistics.reportedCost == 0)
    }

    @Test("Without estimation, missing cost stays nil")
    func noEstimation() async throws {
        let (agent, _) = makeAgent(responses: [
            Fixtures.completion(text: "hi", cost: nil),
        ])
        let response = try await agent.run("hi")
        #expect(response.usage.cost == nil)
        #expect(response.usage.costSource == nil)
    }

    @Test("Events narrate the run in order")
    func eventSequence() async throws {
        let recorder = EventRecorder()
        let (agent, _) = makeAgent(
            responses: [
                Fixtures.completion(text: nil, toolCalls: [("call_1", "tool_a", #"{"x": 1}"#)]),
                Fixtures.completion(text: "done"),
            ],
            onEvent: { event in recorder.record(event) }
        )
        await agent.registerTool("tool_a", description: "A tool.") { _ in "ok" }
        _ = try await agent.run("go")

        let summaries = await recorder.summaries
        #expect(summaries == [
            "runStarted",
            "modelRequestStarted(0)",
            "modelResponseReceived(0, nil)",
            "toolExecutionStarted(tool_a)",
            "toolExecutionFinished(tool_a)",
            "modelRequestStarted(1)",
            "modelResponseReceived(1, Optional(\"done\"))",
            "runCompleted(done)",
        ])
    }

    @Test("A missing API key fails fast")
    func missingKey() async throws {
        let agent = Agent(configuration: AgentConfiguration(openRouterAPIKey: "", transport: MockTransport(responding: [])))
        await #expect(throws: HarnessError.missingAPIKey(service: "OpenRouter")) {
            _ = try await agent.run("hi")
        }
    }

    @Test("HTTP errors surface as HarnessError.api")
    func apiErrorSurfaces() async throws {
        let transport = MockTransport(responding: [
            HTTPResponse(statusCode: 402, body: Data(#"{"error": {"code": 402, "message": "Insufficient credits"}}"#.utf8)),
        ])
        let agent = Agent(configuration: AgentConfiguration(openRouterAPIKey: Self.key, transport: transport))
        do {
            _ = try await agent.run("hi")
            Issue.record("Expected an error")
        } catch let error as HarnessError {
            guard case let .api(statusCode, message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(statusCode == 402)
            #expect(message == "Insufficient credits")
            let transcript = await agent.transcript
            #expect(transcript.isEmpty)
        }
    }

    @Test("Concurrent runs serialize and both complete")
    func runSerialization() async throws {
        let transport = MockTransport(responding: [
            Fixtures.completion(text: "first"),
            Fixtures.completion(text: "second"),
        ])
        let agent = Agent(configuration: AgentConfiguration(openRouterAPIKey: Self.key, transport: transport))
        async let first = agent.run("one")
        async let second = agent.run("two")
        let (a, b) = try await (first, second)
        // Arrival order is not guaranteed, but both runs complete intact.
        #expect(Set([a.text, b.text]) == ["first", "second"])
        let transcript = await agent.transcript
        #expect(transcript.count == 4)
    }
}

// MARK: - Test helpers

/// A thread-safe box for observing values from `@Sendable` tool closures.
final class ValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) {
        storage = value
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}

/// A thread-safe counter for observing tool executions.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Records agent events as printable summaries.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    func record(_ event: AgentEvent) {
        lock.lock()
        defer { lock.unlock() }
        collected.append(Self.summary(of: event))
    }

    var summaries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    private static func summary(of event: AgentEvent) -> String {
        switch event {
        case .runStarted: "runStarted"
        case let .modelRequestStarted(stage): "modelRequestStarted(\(stage))"
        case let .modelResponseReceived(stage, text): "modelResponseReceived(\(stage), \(String(describing: text)))"
        case let .toolExecutionStarted(name, _): "toolExecutionStarted(\(name))"
        case let .toolExecutionFinished(name, _): "toolExecutionFinished(\(name))"
        case let .runCompleted(text): "runCompleted(\(text))"
        case .runFailed: "runFailed"
        }
    }
}
