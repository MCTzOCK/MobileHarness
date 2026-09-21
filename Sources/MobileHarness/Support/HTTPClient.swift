import Foundation

/// An HTTP request issued by the harness.
public struct HTTPRequest: Sendable, Equatable {
    /// The request method, such as `"GET"` or `"POST"`.
    public let method: String
    /// The absolute request URL.
    public let url: URL
    /// The request headers, keyed by canonical field name (for example `"Authorization"`).
    public var headers: [String: String]
    /// The request body, or `nil` for bodyless requests.
    public var body: Data?

    /// Creates a request with the given components.
    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// An HTTP response received by the harness.
public struct HTTPResponse: Sendable, Equatable {
    /// The HTTP status code.
    public let statusCode: Int
    /// The response headers, keyed as received.
    public let headers: [String: String]
    /// The response body.
    public let body: Data

    /// Creates a response with the given components.
    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// The response body decoded as UTF-8 text, or an empty string.
    public var text: String {
        String(decoding: body, as: UTF8.self)
    }

    /// `true` when the status code is in the 200…299 range.
    public var isSuccess: Bool {
        (200..<300).contains(statusCode)
    }
}

/// Transports HTTP requests to remote services.
///
/// The harness talks to OpenRouter and ElevenLabs exclusively through this
/// protocol. Production uses ``URLSessionTransport``; tests substitute a mock
/// transport to exercise the agent loop without network access.
public protocol HTTPTransport: Sendable {
    /// Sends the given request and returns the service's response.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// An `HTTPTransport` backed by `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    /// The session used to execute requests.
    private let session: URLSession

    /// Creates a transport that sends requests over the given session.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: urlRequest)
        let httpResponse = response as? HTTPURLResponse
        let headers = httpResponse?.allHeaderFields.reduce(into: [String: String]()) { partial, pair in
            if let name = pair.key as? String { partial[name] = pair.value as? String }
        } ?? [:]
        return HTTPResponse(
            statusCode: httpResponse?.statusCode ?? 0,
            headers: headers,
            body: data
        )
    }
}

/// Builds `multipart/form-data` bodies.
struct MultipartFormData {
    /// The boundary string separating form parts.
    let boundary: String
    private var parts: [Part] = []

    enum Part {
        case field(name: String, value: String)
        case file(name: String, filename: String, mimeType: String, data: Data)
    }

    /// Creates an empty form with a random boundary.
    init(boundary: String = "MobileHarness-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    /// Appends a plain text form field.
    /// - Returns: The form, for chaining.
    mutating func append(_ name: String, value: String) -> MultipartFormData {
        parts.append(.field(name: name, value: value))
        return self
    }

    /// Appends a file form field.
    /// - Returns: The form, for chaining.
    mutating func append(_ name: String, filename: String, mimeType: String, data: Data) -> MultipartFormData {
        parts.append(.file(name: name, filename: filename, mimeType: mimeType, data: data))
        return self
    }

    /// The value for the request's `Content-Type` header.
    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// The encoded multipart body.
    var body: Data {
        var data = Data()
        func append(_ text: String) { data.append(Data(text.utf8)) }
        for part in parts {
            switch part {
            case let .field(name, value):
                append("--\(boundary)\r\n")
                append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                append("\(value)\r\n")
            case let .file(name, filename, mimeType, fileData):
                append("--\(boundary)\r\n")
                append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
                append("Content-Type: \(mimeType)\r\n\r\n")
                data.append(fileData)
                append("\r\n")
            }
        }
        append("--\(boundary)--\r\n")
        return data
    }
}
