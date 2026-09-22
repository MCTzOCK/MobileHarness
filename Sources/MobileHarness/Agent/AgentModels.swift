import Foundation

/// An OpenRouter server-side tool appended to every request.
///
/// Unlike function tools, the model invokes these and OpenRouter executes
/// them within the request — results return to the model directly, with no
/// client-side tool-call round-trip. Well-known types:
///
/// - `"openrouter:web_search"` — live web search (billed per search)
/// - `"openrouter:web_fetch"` — fetches page content for a URL
/// - `"openrouter:datetime"` — the current date and time
public struct OpenRouterServerTool: Sendable, Hashable {
    /// The OpenRouter tool type, for example `"openrouter:web_search"`.
    public let type: String
    /// Optional tool settings, for example `{"timezone": "Europe/Berlin"}`.
    public let parameters: JSONValue?

    /// Creates a server tool reference.
    public init(type: String, parameters: JSONValue? = nil) {
        self.type = type
        self.parameters = parameters
    }

    /// Live web search; the model decides when and how often to search.
    public static let webSearch = OpenRouterServerTool(type: "openrouter:web_search")

    /// Fetches page content for URLs the model chooses.
    public static let webFetch = OpenRouterServerTool(type: "openrouter:web_fetch")

    /// The current date and time; optionally with an IANA timezone.
    public static func datetime(timezone: String? = nil) -> OpenRouterServerTool {
        if let timezone {
            OpenRouterServerTool(type: "openrouter:datetime", parameters: .object(["timezone": .string(timezone)]))
        } else {
            OpenRouterServerTool(type: "openrouter:datetime")
        }
    }
}

/// The configuration of an ``Agent``.
///
/// Every value except the OpenRouter API key has a sensible default, so the
/// shortest useful configuration is `AgentConfiguration(openRouterAPIKey: key)`.
public struct AgentConfiguration: Sendable {
    /// The model used when none is configured.
    public static let defaultModel = "openai/gpt-4o-mini"

    /// The OpenRouter API key, sent as a bearer token.
    ///
    /// Store this in the keychain with ``KeychainAPIKeyStore`` — never in
    /// `UserDefaults` or embedded source.
    public var openRouterAPIKey: String
    /// The OpenRouter model identifier, for example `"anthropic/claude-sonnet-4.5"`.
    public var model: String
    /// The system prompt establishing the agent's role and behavior.
    public var systemPrompt: String?
    /// The sampling temperature sent to the model, or `nil` for the model default.
    public var temperature: Double?
    /// The maximum number of completion tokens per model turn, or `nil` for the model default.
    public var maxTokens: Int?
    /// How many tool-calling stages a run may perform before failing with
    /// ``HarnessError/maximumToolStagesExceeded(limit:)``.
    ///
    /// A *stage* is one round of tool calls followed by one further model turn;
    /// the default of 8 leaves ample room for multi-step workflows while
    /// protecting against runaway loops.
    public var maxToolStages: Int
    /// OpenRouter server-side tools sent with every request, such as
    /// ``OpenRouterServerTool/webSearch``. OpenRouter executes them as the
    /// model invokes them — no client-side handling is involved.
    public var openRouterServerTools: [OpenRouterServerTool]
    /// Whether to estimate cost locally when OpenRouter does not report one.
    public var estimateCostsWhenMissing: Bool
    /// Overrides the OpenRouter API base URL.
    public var openRouterBaseURL: URL
    /// Overrides the HTTP transport used for OpenRouter requests.
    ///
    /// The default, ``URLSessionTransport``, is right for applications; tests
    /// inject a mock here.
    public var transport: (any HTTPTransport)?
    /// The app name sent to OpenRouter for attribution on openrouter.ai rankings.
    public var applicationName: String?
    /// The app URL sent to OpenRouter for attribution on openrouter.ai rankings.
    public var applicationURL: URL?
    /// Observes the run's progress — model turns, tool executions, completion.
    ///
    /// Events are delivered synchronously on a cooperative thread as the run
    /// proceeds; see ``AgentEvent``.
    public var onEvent: (@Sendable (AgentEvent) -> Void)?

    /// Creates an agent configuration.
    public init(
        openRouterAPIKey: String,
        model: String = AgentConfiguration.defaultModel,
        systemPrompt: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        maxToolStages: Int = 8,
        openRouterServerTools: [OpenRouterServerTool] = [],
        estimateCostsWhenMissing: Bool = true,
        openRouterBaseURL: URL = OpenRouterClient.defaultBaseURL,
        transport: (any HTTPTransport)? = nil,
        applicationName: String? = nil,
        applicationURL: URL? = nil,
        onEvent: (@Sendable (AgentEvent) -> Void)? = nil
    ) {
        self.openRouterAPIKey = openRouterAPIKey
        self.model = model
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.maxToolStages = maxToolStages
        self.openRouterServerTools = openRouterServerTools
        self.estimateCostsWhenMissing = estimateCostsWhenMissing
        self.openRouterBaseURL = openRouterBaseURL
        self.transport = transport
        self.applicationName = applicationName
        self.applicationURL = applicationURL
        self.onEvent = onEvent
    }
}

/// One executed tool call within an agent run, as replayed in ``AgentResponse/stages``.
public struct ToolInvocation: Sendable, Hashable {
    /// The call identifier assigned by the model.
    public let id: String
    /// The name of the executed tool.
    public let toolName: String
    /// The arguments the model supplied.
    public let arguments: [String: JSONValue]
    /// The result fed back to the model.
    public let result: ToolResult
}

/// One stage of tool execution within an agent run.
///
/// A stage is one round of tool calls requested by the model together with
/// their results. Runs that never call tools have no stages; runs that chain
/// tool calls across several model turns have one stage per turn — the
/// *multi-stage* tool calling at the heart of the harness.
public struct ToolStage: Sendable, Hashable {
    /// The one-based index of the stage within the run.
    public let index: Int
    /// The tool calls executed during this stage, in order.
    public let invocations: [ToolInvocation]
}

/// The final result of an agent run.
public struct AgentResponse: Sendable, Hashable {
    /// The assistant's final answer text.
    public let text: String
    /// The model identifier that produced the final answer.
    public let model: String
    /// The tool stages executed along the way, oldest first.
    public let stages: [ToolStage]
    /// The tokens and cost of the entire run, merged across all model turns.
    public let usage: UsageRecord
    /// The normalized finish reason of the final model turn, for example `"stop"`.
    public let finishReason: String?

    /// `true` when the run executed at least one tool call.
    public var usedTools: Bool { !stages.isEmpty }
}

/// Live progress of an agent run, delivered through
/// ``AgentConfiguration``'s `onEvent` handler.
///
/// Events let an app surface the multi-stage loop as it happens — showing which
/// tool is executing, for instance — without changing run results.
public enum AgentEvent: Sendable {
    /// A run began.
    case runStarted
    /// A model turn began; `stage` is the zero-based index of the model turn.
    case modelRequestStarted(stage: Int)
    /// The model's turn arrived. `text` is the assistant content, which is
    /// `nil` when the turn only requests tool calls.
    case modelResponseReceived(stage: Int, text: String?)
    /// A tool execution began with the arguments the model supplied.
    case toolExecutionStarted(name: String, arguments: [String: JSONValue])
    /// A tool execution finished; `result.isError` distinguishes failures.
    case toolExecutionFinished(name: String, result: ToolResult)
    /// The run completed with the given final answer.
    case runCompleted(text: String)
    /// The run failed; the prompt and any partial tool exchanges were rolled
    /// back, so a retried run starts from the conversation as it was before.
    case runFailed(description: String)
}

/// One entry of an agent's conversation ``Agent/transcript``.
public struct TranscriptEntry: Sendable, Hashable {
    /// Who produced the entry.
    public enum Role: String, Sendable, Hashable {
        /// The user's prompt.
        case user
        /// The assistant's answer text.
        case assistant
        /// A tool result shown to the model.
        case tool
    }

    /// The entry's author.
    public let role: Role
    /// The entry's text.
    public let text: String
}
