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

// MARK: - Vision completions

extension OpenRouterClient {

    /// Answers a question about a JPEG image with a vision-capable model.
    ///
    /// A one-shot multimodal completion, separate from any ``Agent``
    /// conversation: the image travels inline as a base64 data URL alongside
    /// the question.
    ///
    /// - Parameters:
    ///   - question: The question or instruction about the image.
    ///   - imageJPEG: Encoded JPEG bytes.
    ///   - model: A vision-capable OpenRouter model identifier.
    ///   - systemPrompt: Optional role instructions for the vision model.
    ///   - maxTokens: Maximum completion tokens; defaults to a spoken-answer
    ///     budget.
    /// - Returns: The model's answer text.
    /// - Throws: ``HarnessError`` on request, transport, or decoding failures.
    public func answerVision(
        question: String,
        imageJPEG: Data,
        model: String,
        systemPrompt: String? = nil,
        maxTokens: Int? = 800
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw HarnessError.missingAPIKey(service: "OpenRouter")
        }
        guard !question.isEmpty, !imageJPEG.isEmpty else {
            throw HarnessError.invalidResponse("Vision requests need a question and a non-empty image.")
        }
        let body = VisionCompletionRequestDTO(
            model: model,
            messages: VisionMessageDTO.messages(question: question, imageJPEG: imageJPEG, systemPrompt: systemPrompt),
            maxTokens: maxTokens
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw HarnessError.invalidResponse("Encoding the vision request failed: \(error)")
        }
        let request = HTTPRequest(
            method: "POST",
            url: baseURL.appendingPathComponent("chat/completions"),
            headers: merged(contentHeaders, authHeaders),
            body: data
        )
        let response = try await send(request, as: ChatCompletionResponseDTO.self)
        guard let text = response.choices.first?.message.content, !text.isEmpty else {
            throw HarnessError.invalidResponse("The vision model returned no text.")
        }
        return text
    }
}

private struct VisionCompletionRequestDTO: Encodable, Sendable {
    let model: String
    let messages: [VisionMessageDTO]
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages
        case maxTokens = "max_tokens"
    }
}

private struct VisionMessageDTO: Encodable, Sendable {
    let role: String
    let content: [ContentPart]

    static func messages(question: String, imageJPEG: Data, systemPrompt: String?) -> [VisionMessageDTO] {
        var messages: [VisionMessageDTO] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(VisionMessageDTO(role: "system", content: [.text(systemPrompt)]))
        }
        messages.append(VisionMessageDTO(role: "user", content: [
            .imageDataURL("data:image/jpeg;base64," + imageJPEG.base64EncodedString()),
            .text(question),
        ]))
        return messages
    }

    enum ContentPart: Encodable, Sendable {
        case text(String)
        case imageDataURL(String)

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .text(text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case let .imageDataURL(url):
                try container.encode("image_url", forKey: .type)
                try container.encode(["url": url], forKey: .imageURL)
            }
        }
    }
}
