import Foundation
import Testing
@testable import MobileHarness

@Suite("OpenRouter client")
struct OpenRouterClientTests {
    static let key = "sk-or-test-key"

    @Test("Chat requests carry auth, headers, model, and generation options")
    func chatRequestShape() async throws {
        let transport = MockTransport(responding: [Fixtures.completion(text: "ok")])
        let client = OpenRouterClient(
            apiKey: Self.key,
            transport: transport,
            applicationName: "MyApp",
            applicationURL: URL(string: "https://myapp.example")
        )
        _ = try await client.complete(
            model: "openai/gpt-4o-mini",
            messages: [.system("Be brief."), .user("Hello")],
            tools: [.function(name: "t", description: "A tool.", parameters: .object([:]))],
            temperature: 0.2,
            maxTokens: 128
        )

        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.headers["Authorization"] == "Bearer \(Self.key)")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["X-Title"] == "MyApp")
        #expect(request.headers["HTTP-Referer"] == "https://myapp.example")

        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.body))
        #expect(body["model"]?.stringValue == "openai/gpt-4o-mini")
        #expect(body["temperature"]?.doubleValue == 0.2)
        #expect(body["max_tokens"]?.intValue == 128)
        #expect(body["tool_choice"]?.stringValue == "auto")
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.compactMap { $0["role"]?.stringValue } == ["system", "user"])
    }

    @Test("Without tools, tool fields are omitted")
    func noToolsOmitsFields() async throws {
        let transport = MockTransport(responding: [Fixtures.completion(text: "ok")])
        let client = OpenRouterClient(apiKey: Self.key, transport: transport)
        _ = try await client.complete(
            model: "m",
            messages: [.user("hi")],
            tools: [],
            temperature: nil,
            maxTokens: nil
        )
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(transport.requests.first?.body))
        #expect(body["tools"] == nil)
        #expect(body["tool_choice"] == nil)
        #expect(body["temperature"] == nil)
        #expect(body["max_tokens"] == nil)
    }

    @Test("Responses with tool calls decode, including usage cost")
    func toolCallDecoding() throws {
        let json = Fixtures.completionBody(
            text: nil,
            toolCalls: [("call_9", "get_weather", #"{"city": "Berlin"}"#)],
            cost: 0.000123
        )
        let response = try JSONDecoder().decode(ChatCompletionResponseDTO.self, from: Data(json.utf8))
        let message = try #require(response.choices.first?.message)
        let call = try #require(message.toolCalls?.first)
        #expect(call.id == "call_9")
        #expect(call.function.name == "get_weather")
        #expect(call.function.arguments == #"{"city": "Berlin"}"#)
        #expect(response.usage?.cost == 0.000123)
        #expect(response.usage?.promptTokens == 10)
    }

    @Test("Responses tolerate missing usage and null content")
    func sparseResponse() throws {
        let json = """
        {"id": "x", "object": "chat.completion", "created": 1, "model": "m",
         "choices": [{"index": 0, "message": {"role": "assistant", "content": null}, "finish_reason": "stop"}]}
        """
        let response = try JSONDecoder().decode(ChatCompletionResponseDTO.self, from: Data(json.utf8))
        #expect(response.usage == nil)
        #expect(response.choices.first?.message.content == nil)
        #expect(response.choices.first?.message.toolCalls == nil)
    }

    @Test("fetchModelPricing converts string prices to exact decimals")
    func pricingFetch() async throws {
        let transport = MockTransport(responding: [
            HTTPResponse(statusCode: 200, body: Data(Fixtures.modelsBody().utf8)),
        ])
        let client = OpenRouterClient(apiKey: Self.key, transport: transport)
        let pricing = try await client.fetchModelPricing()
        #expect(pricing.count == 2)
        let mini = try #require(pricing.first { $0.modelID == "openai/gpt-4o-mini" })
        #expect(mini.promptTokenPrice == Decimal(string: "0.00000015"))
        #expect(mini.completionTokenPrice == Decimal(string: "0.0000006"))
        #expect(mini.cost(promptTokens: 1000, completionTokens: 500) == Decimal(string: "0.00045"))
    }

    @Test("fetchAPIKeyInfo maps account usage")
    func keyInfo() async throws {
        let transport = MockTransport(responding: [
            HTTPResponse(statusCode: 200, body: Data(Fixtures.keyInfoBody().utf8)),
        ])
        let client = OpenRouterClient(apiKey: Self.key, transport: transport)
        let info = try await client.fetchAPIKeyInfo()
        #expect(info.label == "sk-or-v1-…test")
        #expect(info.totalUsage == Decimal(string: "25.5"))
        #expect(info.dailyUsage == Decimal(string: "1.5"))
        #expect(info.spendingLimit == 100)
        #expect(info.spendingLimitRemaining == Decimal(string: "74.5"))
        #expect(!info.isFreeTier)
        #expect(info.freeModelRequestsRemaining == 38)
        #expect(info.rateLimitRequests == 1000)
        #expect(info.rateLimitInterval == "1h")
    }

    @Test("Service errors surface the message from the error envelope")
    func errorEnvelope() async throws {
        let transport = MockTransport(responding: [
            HTTPResponse(statusCode: 401, body: Data(#"{"error": {"code": 401, "message": "Invalid key"}}"#.utf8)),
        ])
        let client = OpenRouterClient(apiKey: "bad", transport: transport)
        await #expect(throws: HarnessError.api(statusCode: 401, message: "Invalid key")) {
            _ = try await client.fetchAPIKeyInfo()
        }
    }

    @Test("Malformed success bodies throw invalidResponse")
    func malformedBody() async throws {
        let transport = MockTransport(responding: [
            HTTPResponse(statusCode: 200, body: Data("not json".utf8)),
        ])
        let client = OpenRouterClient(apiKey: Self.key, transport: transport)
        do {
            _ = try await client.fetchAPIKeyInfo()
            Issue.record("Expected an error")
        } catch let error as HarnessError {
            guard case .invalidResponse = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }
}

@Suite("Cost estimator")
struct CostEstimatorTests {
    @Test("Estimates from primed pricing without network")
    func primedEstimate() async throws {
        let estimator = CostEstimator()
        await estimator.prime(with: [
            ModelPricing(modelID: "openai/gpt-4o-mini", promptTokenPrice: Decimal(string: "0.00000015")!, completionTokenPrice: Decimal(string: "0.0000006")!),
        ])
        let cost = try await estimator.estimatedCost(model: "openai/gpt-4o-mini", promptTokens: 1000, completionTokens: 500)
        #expect(cost == Decimal(string: "0.00045"))
    }

    @Test("Variant model IDs fall back to their base model pricing")
    func variantFallback() async throws {
        let transport = MockTransport(routing: { _ in
            HTTPResponse(statusCode: 200, body: Data(Fixtures.modelsBody().utf8))
        })
        let estimator = CostEstimator(client: OpenRouterClient(apiKey: "k", transport: transport))
        let cost = try await estimator.estimatedCost(model: "openai/gpt-4o:free", promptTokens: 1000, completionTokens: 0)
        // gpt-4o prompt price 0.0000025 * 1000
        #expect(cost == Decimal(string: "0.0025"))
    }

    @Test("Unknown models throw")
    func unknownModel() async throws {
        let estimator = CostEstimator()
        await estimator.prime(with: [])
        do {
            _ = try await estimator.estimatedCost(model: "no/such-model", promptTokens: 1, completionTokens: 1)
            Issue.record("Expected an error")
        } catch let error as HarnessError {
            guard case .invalidResponse = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test("refresh reloads pricing from the client")
    func refresh() async throws {
        let transport = MockTransport(routing: { _ in
            HTTPResponse(statusCode: 200, body: Data(Fixtures.modelsBody().utf8))
        })
        let estimator = CostEstimator(client: OpenRouterClient(apiKey: "k", transport: transport))
        try await estimator.refresh()
        let cost = try await estimator.estimatedCost(model: "openai/gpt-4o-mini", promptTokens: 0, completionTokens: 1000)
        // 1000 * 0.0000006
        #expect(cost == Decimal(string: "0.0006"))
    }

    @Test("Without a client, refresh throws")
    func noClientRefresh() async throws {
        let estimator = CostEstimator()
        do {
            try await estimator.refresh()
            Issue.record("Expected an error")
        } catch let error as HarnessError {
            guard case .invalidResponse = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }
}
