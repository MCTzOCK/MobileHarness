import Foundation
@testable import MobileHarness

/// An ``HTTPTransport`` that records requests and answers from a script.
///
/// Responses are dequeued in order; when the queue empties, the last response
/// repeats. Alternatively pass a routing closure for path-dependent responses.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [HTTPResponse]
    private var router: (@Sendable (HTTPRequest) throws -> HTTPResponse)?
    private(set) var requests: [HTTPRequest] = []

    /// Creates a transport answering with the given responses in order.
    init(responding responses: [HTTPResponse]) {
        queue = responses
    }

    /// Creates a transport answering from the given routing closure.
    init(routing router: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
        queue = []
        self.router = router
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try lock.withLock {
            requests.append(request)
            if let router {
                return Result { try router(request) }
            }
            guard !queue.isEmpty else {
                return .failure(HarnessError.invalidResponse("MockTransport received an unexpected request: \(request.method) \(request.url)"))
            }
            if queue.count == 1 { return .success(queue[0]) }
            return .success(queue.removeFirst())
        }
        return try response.get()
    }
}

// MARK: - OpenRouter response fixtures

enum Fixtures {
    /// A chat completion response body.
    static func completionBody(
        text: String?,
        toolCalls: [(id: String, name: String, arguments: String)] = [],
        model: String = "openai/gpt-4o-mini",
        finishReason: String = "stop",
        promptTokens: Int? = 10,
        completionTokens: Int? = 5,
        cost: Double? = nil
    ) -> String {
        let toolCallsJSON = toolCalls.map { call in
            """
            {"id": "\(call.id)", "type": "function", "function": {"name": "\(call.name)", "arguments": "\(call.arguments.replacingOccurrences(of: "\"", with: "\\\""))"}}
            """
        }.joined(separator: ",")
        let contentJSON = text.map { "\"\($0)\"" } ?? "null"
        let toolCallsFragment = toolCalls.isEmpty ? "" : ", \"tool_calls\": [\(toolCallsJSON)]"
        let usageCost = cost.map { ", \"cost\": \($0)" } ?? ""
        return """
        {
          "id": "chatcmpl-test",
          "object": "chat.completion",
          "created": 1677652288,
          "model": "\(model)",
          "choices": [
            {
              "index": 0,
              "message": {"role": "assistant", "content": \(contentJSON)\(toolCallsFragment)},
              "finish_reason": "\(toolCalls.isEmpty ? finishReason : "tool_calls")"
            }
          ],
          "usage": {"prompt_tokens": \(promptTokens ?? 0), "completion_tokens": \(completionTokens ?? 0), "total_tokens": \((promptTokens ?? 0) + (completionTokens ?? 0))\(usageCost)}
        }
        """
    }

    /// A chat completion HTTP response.
    static func completion(
        text: String?,
        toolCalls: [(id: String, name: String, arguments: String)] = [],
        model: String = "openai/gpt-4o-mini",
        promptTokens: Int? = 10,
        completionTokens: Int? = 5,
        cost: Double? = nil
    ) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(completionBody(
                text: text,
                toolCalls: toolCalls,
                model: model,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                cost: cost
            ).utf8)
        )
    }

    /// A model pricing list body for `GET /models`.
    static func modelsBody() -> String {
        """
        {
          "data": [
            {"id": "openai/gpt-4o-mini", "name": "GPT-4o mini", "pricing": {"prompt": "0.00000015", "completion": "0.0000006", "request": "0"}},
            {"id": "openai/gpt-4o", "name": "GPT-4o", "pricing": {"prompt": "0.0000025", "completion": "0.00001", "request": "0"}}
          ]
        }
        """
    }

    /// An API key info body for `GET /key`.
    static func keyInfoBody() -> String {
        """
        {
          "data": {
            "label": "sk-or-v1-…test",
            "usage": 25.5,
            "usage_daily": 1.5,
            "usage_weekly": 4.5,
            "usage_monthly": 25.5,
            "limit": 100,
            "limit_remaining": 74.5,
            "is_free_tier": false,
            "free_model_daily_requests": {"limit": 50, "remaining": 38, "used": 12},
            "rate_limit": {"requests": 1000, "interval": "1h"}
          }
        }
        """
    }
}
