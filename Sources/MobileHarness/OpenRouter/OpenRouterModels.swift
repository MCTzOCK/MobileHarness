import Foundation

// MARK: - Chat messages

/// A chat message in the OpenRouter wire format.
///
/// The shape mirrors the OpenAI Chat schema OpenRouter normalizes to: assistant
/// messages may carry tool calls, and tool messages reply to a specific call.
struct WireMessage: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case system(String)
        case user(String)
        case assistant(content: String?, toolCalls: [WireToolCall])
        case tool(toolCallID: String, content: String)
    }

    var kind: Kind

    static func system(_ content: String) -> WireMessage {
        WireMessage(kind: .system(content))
    }

    static func user(_ content: String) -> WireMessage {
        WireMessage(kind: .user(content))
    }

    static func assistant(content: String?, toolCalls: [WireToolCall] = []) -> WireMessage {
        WireMessage(kind: .assistant(content: content, toolCalls: toolCalls))
    }

    static func tool(toolCallID: String, content: String) -> WireMessage {
        WireMessage(kind: .tool(toolCallID: toolCallID, content: content))
    }
}

/// A tool call requested by the model, in wire format.
struct WireToolCall: Sendable, Equatable {
    /// The identifier used to correlate the follow-up tool result message.
    let id: String
    /// The name of the tool to execute.
    let name: String
    /// The JSON-encoded object of arguments as sent by the model.
    let argumentsJSON: String
}

extension WireToolCall: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case function
    }

    init(from decoder: Decoder) throws {
        struct FunctionEnvelope: Decodable {
            let name: String
            let arguments: String
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let envelope = try container.decode(FunctionEnvelope.self, forKey: .function)
        name = envelope.name
        argumentsJSON = envelope.arguments
    }

    func encode(to encoder: Encoder) throws {
        struct FunctionEnvelope: Encodable {
            let name: String
            let arguments: String
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode("function", forKey: .type)
        try container.encode(FunctionEnvelope(name: name, arguments: argumentsJSON), forKey: .function)
    }
}

// MARK: - Request

/// The request body for `POST /chat/completions`.
struct ChatCompletionRequestDTO: Encodable, Sendable, Equatable {
    struct ToolDefinition: Encodable, Sendable, Equatable {
        struct Function: Encodable, Sendable, Equatable {
            let name: String
            let description: String
            /// A JSON Schema object describing the arguments.
            let parameters: JSONValue
        }

        let type: String
        let function: Function

        static func function(name: String, description: String, parameters: JSONValue) -> ToolDefinition {
            ToolDefinition(type: "function", function: Function(name: name, description: description, parameters: parameters))
        }
    }

    let model: String
    let messages: [WireMessage]
    let tools: [ToolDefinition]?
    let toolChoice: String?
    let temperature: Double?
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, tools
        case toolChoice = "tool_choice"
        case temperature
        case maxTokens = "max_tokens"
    }
}

// MARK: - Response

/// The response body of `POST /chat/completions`.
struct ChatCompletionResponseDTO: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Message: Decodable, Sendable {
            struct ToolCall: Decodable, Sendable {
                struct Function: Decodable, Sendable {
                    let name: String
                    let arguments: String
                }

                let id: String
                let function: Function
            }

            let role: String?
            let content: String?
            let toolCalls: [ToolCall]?

            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
            }
        }

        let index: Int?
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Decodable, Sendable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let cost: Double?

        enum CodingKeys: String, CodingKey {
            case cost
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }

    let id: String?
    let model: String?
    let choices: [Choice]
    let usage: Usage?
}

// MARK: - Codable for messages

extension WireMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case role, content, toolCalls = "tool_calls", toolCallID = "tool_call_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decode(String.self, forKey: .role)
        switch role {
        case "system", "developer":
            self.init(kind: .system(try container.decode(String.self, forKey: .content)))
        case "user":
            self.init(kind: .user(try container.decode(String.self, forKey: .content)))
        case "assistant":
            let content = try container.decodeIfPresent(String.self, forKey: .content)
            let toolCalls = (try container.decodeIfPresent([WireToolCall].self, forKey: .toolCalls)) ?? []
            self.init(kind: .assistant(content: content, toolCalls: toolCalls))
        case "tool":
            self.init(kind: .tool(
                toolCallID: try container.decode(String.self, forKey: .toolCallID),
                content: try container.decode(String.self, forKey: .content)
            ))
        default:
            let context = DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported message role \"\(role)\"."
            )
            throw DecodingError.dataCorrupted(context)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch kind {
        case let .system(content):
            try container.encode("system", forKey: .role)
            try container.encode(content, forKey: .content)
        case let .user(content):
            try container.encode("user", forKey: .role)
            try container.encode(content, forKey: .content)
        case let .assistant(content, toolCalls):
            try container.encode("assistant", forKey: .role)
            try container.encodeIfPresent(content, forKey: .content)
            if !toolCalls.isEmpty {
                try container.encode(toolCalls, forKey: .toolCalls)
            }
        case let .tool(toolCallID, content):
            try container.encode("tool", forKey: .role)
            try container.encode(content, forKey: .content)
            try container.encode(toolCallID, forKey: .toolCallID)
        }
    }
}

// MARK: - Model pricing

/// The per-token price of one model, in USD.
public struct ModelPricing: Sendable, Hashable {
    /// The OpenRouter model identifier, for example `"openai/gpt-4o-mini"`.
    public let modelID: String
    /// The USD price per prompt (input) token.
    public let promptTokenPrice: Decimal
    /// The USD price per completion (output) token.
    public let completionTokenPrice: Decimal
    /// The flat USD price per request.
    public let requestPrice: Decimal

    /// Creates a pricing entry.
    public init(modelID: String, promptTokenPrice: Decimal, completionTokenPrice: Decimal, requestPrice: Decimal = 0) {
        self.modelID = modelID
        self.promptTokenPrice = promptTokenPrice
        self.completionTokenPrice = completionTokenPrice
        self.requestPrice = requestPrice
    }

    /// Returns the estimated USD cost of a completion with the given token counts.
    public func cost(promptTokens: Int, completionTokens: Int) -> Decimal {
        requestPrice
            + promptTokenPrice * Decimal(promptTokens)
            + completionTokenPrice * Decimal(completionTokens)
    }
}

/// The response body of `GET /models`, reduced to pricing fields.
struct ModelListResponseDTO: Decodable, Sendable {
    struct ModelEntry: Decodable, Sendable {
        struct Pricing: Decodable, Sendable {
            let prompt: String?
            let completion: String?
            let request: String?
        }

        let id: String
        let name: String?
        let pricing: Pricing?
    }

    let data: [ModelEntry]
}

// MARK: - API key info

/// Account-level usage and limits for the configured OpenRouter API key.
///
/// Returned by ``OpenRouterClient/fetchAPIKeyInfo()``; useful for dashboards
/// that show remaining budget alongside the agent's own
/// ``UsageStatistics``.
public struct APIKeyInfo: Sendable, Hashable {
    /// The (partially masked) label of the key.
    public let label: String?
    /// Total USD spent with this key over its lifetime.
    public let totalUsage: Decimal?
    /// USD spent with this key today.
    public let dailyUsage: Decimal?
    /// USD spent with this key this week.
    public let weeklyUsage: Decimal?
    /// USD spent with this key this month.
    public let monthlyUsage: Decimal?
    /// The spending cap set on the key, or `nil` when unlimited.
    public let spendingLimit: Decimal?
    /// USD remaining before the spending cap is reached, or `nil` when unlimited.
    public let spendingLimitRemaining: Decimal?
    /// Whether the key belongs to a free-tier account.
    public let isFreeTier: Bool
    /// Free-model requests used today.
    public let freeModelRequestsUsed: Int?
    /// Free-model requests still available today.
    public let freeModelRequestsRemaining: Int?
    /// The number of requests allowed per rate-limit interval.
    public let rateLimitRequests: Int?
    /// The rate-limit interval, for example `"1h"`.
    public let rateLimitInterval: String?
}

/// The response body of `GET /key`, reduced to the fields in ``APIKeyInfo``.
struct KeyInfoResponseDTO: Decodable, Sendable {
    struct Data: Decodable, Sendable {
        struct DailyRequests: Decodable, Sendable {
            let limit: Int?
            let remaining: Int?
            let used: Int?
        }

        struct RateLimit: Decodable, Sendable {
            let requests: Int?
            let interval: String?
        }

        let label: String?
        let usage: Double?
        let usageDaily: Double?
        let usageWeekly: Double?
        let usageMonthly: Double?
        let limit: Double?
        let limitRemaining: Double?
        let isFreeTier: Bool?
        let freeModelDailyRequests: DailyRequests?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case label, usage, limit
            case usageDaily = "usage_daily"
            case usageWeekly = "usage_weekly"
            case usageMonthly = "usage_monthly"
            case limitRemaining = "limit_remaining"
            case isFreeTier = "is_free_tier"
            case freeModelDailyRequests = "free_model_daily_requests"
            case rateLimit = "rate_limit"
        }
    }

    let data: Data
}

// MARK: - Error envelope

/// The error body returned by OpenRouter on failures.
struct APIErrorEnvelopeDTO: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        let code: Int?
        let message: String?
    }

    let error: Payload?
}
