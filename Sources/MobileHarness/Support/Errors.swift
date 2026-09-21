import Security

/// The error types reported by MobileHarness.
///
/// All failures thrown by the harness surface as ``HarnessError``, with the
/// case payload carrying the information an application needs to react — for
/// example by prompting the user to top up credits when
/// ``HarnessError/api(statusCode:message:)`` reports HTTP 402.
public enum HarnessError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A remote service answered with a non-success HTTP status code.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code returned by the service.
    ///   - message: The human-readable error message returned by the service, if any.
    case api(statusCode: Int, message: String)

    /// A remote service answered with a payload that could not be decoded.
    case invalidResponse(String)

    /// The model kept requesting tool executions without producing a final
    /// answer, exceeding the configured stage limit.
    ///
    /// The associated value is the limit that was exceeded; raise
    /// ``AgentConfiguration/maxToolStages`` if legitimate workflows need more
    /// stages.
    case maximumToolStagesExceeded(limit: Int)

    /// A required API key is missing or empty.
    case missingAPIKey(service: String)

    /// Speech synthesis failed.
    case speechSynthesisFailed(String)

    /// Speech-to-text transcription failed.
    case transcriptionFailed(String)

    /// Microphone recording failed — for example because no input device is
    /// available or microphone permission was denied.
    case recordingFailed(String)

    /// Audio playback failed.
    case playbackFailed(String)

    /// A keychain operation failed.
    ///
    /// The associated value is the raw `OSStatus` returned by Security.framework.
    case keychainStatus(OSStatus)

    public var description: String {
        switch self {
        case let .api(statusCode, message):
            "API request failed (HTTP \(statusCode)): \(message)"
        case let .invalidResponse(detail):
            "The service returned an unexpected response: \(detail)"
        case let .maximumToolStagesExceeded(limit):
            "The agent exceeded its limit of \(limit) tool stages without producing a final answer."
        case let .missingAPIKey(service):
            "A required API key for \(service) is missing."
        case let .speechSynthesisFailed(detail):
            "Speech synthesis failed: \(detail)"
        case let .transcriptionFailed(detail):
            "Transcription failed: \(detail)"
        case let .recordingFailed(detail):
            "Recording failed: \(detail)"
        case let .playbackFailed(detail):
            "Audio playback failed: \(detail)"
        case let .keychainStatus(status):
            "A keychain operation failed with status \(status)."
        }
    }
}
