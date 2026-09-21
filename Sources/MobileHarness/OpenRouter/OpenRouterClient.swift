import Foundation

/// The OpenRouter API client used by ``Agent`` and exposed for direct use.
///
/// The client is a value type that carries credentials and transport only; it
/// is safe to share across concurrency domains. All methods throw
/// ``HarnessError`` on failure.
public struct OpenRouterClient: Sendable {
    /// The default OpenRouter API base URL.
    public static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1")!

    /// The OpenRouter API key sent as a bearer token.
    private let apiKey: String
    /// The API base URL.
    private let baseURL: URL
    /// The transport used to execute HTTP requests.
    private let transport: any HTTPTransport
    /// Extra identifying headers sent with every request (OpenRouter app rankings).
    private let extraHeaders: [String: String]

    /// Creates a client for the given key.
    ///
    /// - Parameters:
    ///   - apiKey: The OpenRouter API key (`sk-or-…`).
    ///   - baseURL: Overrides the OpenRouter API base URL; used by tests.
    ///   - transport: Overrides the HTTP transport; used by tests.
    ///   - applicationName: Sent as `X-Title` so the app is attributed on
    ///     openrouter.ai rankings.
    ///   - applicationURL: Sent as `HTTP-Referer` so the app is attributed on
    ///     openrouter.ai rankings.
    public init(
        apiKey: String,
        baseURL: URL = OpenRouterClient.defaultBaseURL,
        transport: (any HTTPTransport)? = nil,
        applicationName: String? = nil,
        applicationURL: URL? = nil
    ) {
        var headers: [String: String] = [:]
        if let applicationName { headers["X-Title"] = applicationName }
        if let applicationURL { headers["HTTP-Referer"] = applicationURL.absoluteString }
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transport = transport ?? URLSessionTransport()
        self.extraHeaders = headers
    }

    /// Performs a chat completion, the single model turn of the agent loop.
    ///
    /// - Parameters:
    ///   - model: The model identifier, for example `"openai/gpt-4o-mini"`.
    ///   - messages: The conversation so far, oldest first.
    ///   - tools: The tool definitions the model may call.
    ///   - temperature: Sampling temperature, or `nil` for the model default.
    ///   - maxTokens: Maximum completion tokens, or `nil` for the model default.
    /// - Returns: The decoded completion, whose message may carry tool calls.
    func complete(
        model: String,
        messages: [WireMessage],
        tools: [ChatCompletionRequestDTO.ToolDefinition],
        temperature: Double?,
        maxTokens: Int?
    ) async throws -> ChatCompletionResponseDTO {
        let body = ChatCompletionRequestDTO(
            model: model,
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            toolChoice: tools.isEmpty ? nil : "auto",
            temperature: temperature,
            maxTokens: maxTokens
        )
        let data = try encodeBody(body)
        let request = HTTPRequest(
            method: "POST",
            url: baseURL.appendingPathComponent("chat/completions"),
            headers: merged(contentHeaders, authHeaders),
            body: data
        )
        return try await send(request, as: ChatCompletionResponseDTO.self)
    }

    /// Fetches the published per-token pricing of every OpenRouter model.
    ///
    /// This is the pricing table behind ``CostEstimator``; no API key usage is
    /// required for the call itself.
    public func fetchModelPricing() async throws -> [ModelPricing] {
        let request = HTTPRequest(
            method: "GET",
            url: baseURL.appendingPathComponent("models"),
            headers: apiKey.isEmpty ? extraHeaders : merged(extraHeaders, authHeaders)
        )
        let response = try await send(request, as: ModelListResponseDTO.self)
        return response.data.compactMap { entry in
            guard let pricing = entry.pricing else { return nil }
            return ModelPricing(
                modelID: entry.id,
                promptTokenPrice: Decimal(usdString: pricing.prompt ?? "0"),
                completionTokenPrice: Decimal(usdString: pricing.completion ?? "0"),
                requestPrice: Decimal(usdString: pricing.request ?? "0")
            )
        }
    }

    /// Fetches account-level usage and limits for the configured API key.
    public func fetchAPIKeyInfo() async throws -> APIKeyInfo {
        let request = HTTPRequest(
            method: "GET",
            url: baseURL.appendingPathComponent("key"),
            headers: merged(extraHeaders, authHeaders)
        )
        let response = try await send(request, as: KeyInfoResponseDTO.self)
        let data = response.data
        return APIKeyInfo(
            label: data.label,
            totalUsage: data.usage.map { Decimal(usdDouble: $0) },
            dailyUsage: data.usageDaily.map { Decimal(usdDouble: $0) },
            weeklyUsage: data.usageWeekly.map { Decimal(usdDouble: $0) },
            monthlyUsage: data.usageMonthly.map { Decimal(usdDouble: $0) },
            spendingLimit: data.limit.map { Decimal(usdDouble: $0) },
            spendingLimitRemaining: data.limitRemaining.map { Decimal(usdDouble: $0) },
            isFreeTier: data.isFreeTier ?? false,
            freeModelRequestsUsed: data.freeModelDailyRequests?.used,
            freeModelRequestsRemaining: data.freeModelDailyRequests?.remaining,
            rateLimitRequests: data.rateLimit?.requests,
            rateLimitInterval: data.rateLimit?.interval
        )
    }

    // MARK: - Internals

    private var authHeaders: [String: String] {
        guard !apiKey.isEmpty else { return [:] }
        return ["Authorization": "Bearer \(apiKey)"]
    }

    private var contentHeaders: [String: String] {
        merged(extraHeaders, ["Content-Type": "application/json"])
    }

    /// Combines header dictionaries, with later dictionaries winning key conflicts.
    private func merged(_ dictionaries: [String: String]...) -> [String: String] {
        dictionaries.reduce(into: [:]) { $0.merge($1) { _, new in new } }
    }

    private func encodeBody(_ body: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        do {
            return try encoder.encode(body)
        } catch {
            throw HarnessError.invalidResponse("Encoding the request failed: \(error)")
        }
    }

    private func send<Response: Decodable>(_ request: HTTPRequest, as type: Response.Type) async throws -> Response {
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw apiError(for: response)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            throw HarnessError.invalidResponse(
                "Decoding \(String(describing: Response.self)) failed: \(error). Body: \(String(decoding: response.body.prefix(500), as: UTF8.self))"
            )
        }
    }

    private func apiError(for response: HTTPResponse) -> HarnessError {
        let message = (try? JSONDecoder().decode(APIErrorEnvelopeDTO.self, from: response.body))?.error?.message
            ?? String(decoding: response.body.prefix(500), as: UTF8.self)
        return HarnessError.api(statusCode: response.statusCode, message: message)
    }
}
