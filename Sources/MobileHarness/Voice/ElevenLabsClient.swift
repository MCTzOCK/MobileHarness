import Foundation

/// The ElevenLabs client powering speech synthesis and recognition.
///
/// ``VoiceSession`` composes this client with an ``Agent``; the client is also
/// exposed directly for apps that want speech features on their own terms.
public struct ElevenLabsClient: Sendable {
    /// The default ElevenLabs API base URL.
    public static let defaultBaseURL = URL(string: "https://api.elevenlabs.io/v1")!

    /// The default voice — "Rachel", a natural female premade voice.
    public static let defaultVoiceID = "21m00Tcm4TlvDq8ikWAM"

    private let apiKey: String
    private let baseURL: URL
    private let transport: any HTTPTransport

    /// Creates a client for the given key.
    ///
    /// - Parameters:
    ///   - apiKey: The ElevenLabs API key.
    ///   - baseURL: Overrides the ElevenLabs API base URL; used by tests.
    ///   - transport: Overrides the HTTP transport; used by tests.
    public init(
        apiKey: String,
        baseURL: URL = ElevenLabsClient.defaultBaseURL,
        transport: (any HTTPTransport)? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transport = transport ?? URLSessionTransport()
    }

    /// Synthesizes speech from text.
    ///
    /// - Parameters:
    ///   - text: The text to speak.
    ///   - voiceID: The voice identifier; defaults to ElevenLabs' "Rachel".
    ///   - model: The speech model; defaults to ``SpeechModel/multilingualV2``.
    ///   - settings: Voice delivery settings.
    ///   - outputFormat: The audio container of the returned bytes.
    /// - Returns: The encoded audio, playable with ``SpeechPlayer``.
    /// - Throws: ``HarnessError/speechSynthesisFailed(_:)`` or
    ///   ``HarnessError/api(statusCode:message:)`` on service errors.
    public func synthesizeSpeech(
        from text: String,
        voiceID: String = ElevenLabsClient.defaultVoiceID,
        model: SpeechModel = .multilingualV2,
        settings: VoiceSettings = VoiceSettings(),
        outputFormat: AudioOutputFormat = .mp3_44100_128
    ) async throws -> Data {
        guard !apiKey.isEmpty else {
            throw HarnessError.missingAPIKey(service: "ElevenLabs")
        }
        guard !text.isEmpty else {
            throw HarnessError.speechSynthesisFailed("The text to synthesize is empty.")
        }
        let body = SpeechRequestDTO(
            text: text,
            modelID: model.rawValue,
            voiceSettings: .init(
                stability: settings.stability,
                similarityBoost: settings.similarityBoost,
                style: settings.style,
                useSpeakerBoost: settings.useSpeakerBoost,
                speed: settings.speed
            )
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw HarnessError.invalidResponse("Encoding the speech request failed: \(error)")
        }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("text-to-speech").appendingPathComponent(voiceID),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "output_format", value: outputFormat.rawValue)]
        let request = HTTPRequest(
            method: "POST",
            url: components.url!,
            headers: [
                "xi-api-key": apiKey,
                "Content-Type": "application/json",
            ],
            body: data
        )
        let response = try await transport.send(request)
        guard response.isSuccess, !response.body.isEmpty else {
            throw HarnessError.speechSynthesisFailed(errorMessage(for: response))
        }
        return response.body
    }

    /// Transcribes recorded speech to text.
    ///
    /// - Parameters:
    ///   - recording: The audio clip, as produced by ``MicrophoneRecorder``.
    ///   - model: The recognition model; defaults to ``SpeechRecognitionModel/scribeV1``.
    ///   - languageCode: An optional ISO 639-1 hint; omitted to auto-detect.
    /// - Returns: The transcript with detected language.
    /// - Throws: ``HarnessError/transcriptionFailed(_:)`` or
    ///   ``HarnessError/api(statusCode:message:)`` on service errors.
    public func transcribeSpeech(
        in recording: AudioRecording,
        model: SpeechRecognitionModel = .scribeV1,
        languageCode: String? = nil
    ) async throws -> Transcription {
        guard !apiKey.isEmpty else {
            throw HarnessError.missingAPIKey(service: "ElevenLabs")
        }
        guard !recording.data.isEmpty else {
            throw HarnessError.transcriptionFailed("The recording to transcribe is empty.")
        }
        var form = MultipartFormData()
        form.append("model_id", value: model.rawValue)
        if let languageCode {
            form.append("language_code", value: languageCode)
        }
        form.append(
            "file",
            filename: recording.filename,
            mimeType: recording.mimeType,
            data: recording.data
        )
        let request = HTTPRequest(
            method: "POST",
            url: baseURL.appendingPathComponent("speech-to-text"),
            headers: [
                "xi-api-key": apiKey,
                "Content-Type": form.contentType,
            ],
            body: form.body
        )
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw HarnessError.transcriptionFailed(errorMessage(for: response))
        }
        do {
            let dto = try JSONDecoder().decode(TranscriptionResponseDTO.self, from: response.body)
            return Transcription(
                text: dto.text ?? "",
                languageCode: dto.languageCode,
                languageProbability: dto.languageProbability
            )
        } catch let error as HarnessError {
            throw error
        } catch {
            throw HarnessError.transcriptionFailed(
                "Decoding the transcript failed: \(error). Body: \(String(decoding: response.body.prefix(500), as: UTF8.self))"
            )
        }
    }

    /// Lists the voices available to the account, premade and cloned.
    public func listVoices() async throws -> [ElevenLabsVoice] {
        guard !apiKey.isEmpty else {
            throw HarnessError.missingAPIKey(service: "ElevenLabs")
        }
        let request = HTTPRequest(
            method: "GET",
            url: baseURL.appendingPathComponent("voices"),
            headers: ["xi-api-key": apiKey]
        )
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw HarnessError.api(statusCode: response.statusCode, message: errorMessage(for: response))
        }
        do {
            let dto = try JSONDecoder().decode(VoiceListResponseDTO.self, from: response.body)
            return dto.voices.compactMap { voice in
                guard let id = voice.id else { return nil }
                return ElevenLabsVoice(id: id, name: voice.name, category: voice.category)
            }
        } catch {
            throw HarnessError.invalidResponse(
                "Decoding the voice list failed: \(error). Body: \(String(decoding: response.body.prefix(500), as: UTF8.self))"
            )
        }
    }

    // MARK: - Error mapping

    /// Extracts a human-readable message from an ElevenLabs error body.
    ///
    /// ElevenLabs reports errors as `{"detail": {"message": …}}` for service
    /// errors and as `{"detail": [{"msg": …}]}` for validation errors; both are
    /// tolerated, with the raw body as a last resort.
    private func errorMessage(for response: HTTPResponse) -> String {
        let fallback = String(decoding: response.body.prefix(500), as: UTF8.self)
        struct ObjectDetail: Decodable {
            let message: String?
            let status: String?
        }
        struct ListDetail: Decodable {
            let msg: String?
        }
        struct Envelope: Decodable {
            let detail: Detail?
            enum Detail: Decodable {
                case object(ObjectDetail)
                case list([ListDetail])
                case text(String)

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let object = try? container.decode(ObjectDetail.self) {
                        self = .object(object)
                    } else if let list = try? container.decode([ListDetail].self) {
                        self = .list(list)
                    } else if let text = try? container.decode(String.self) {
                        self = .text(text)
                    } else {
                        throw DecodingError.dataCorruptedError(
                            in: container,
                            debugDescription: "Unrecognized ElevenLabs error detail."
                        )
                    }
                }
            }
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.body) else {
            return "HTTP \(response.statusCode): \(fallback)"
        }
        switch envelope.detail {
        case let .object(object):
            let parts = [object.status, object.message].compactMap { $0 }
            return "HTTP \(response.statusCode): \(parts.joined(separator: " — "))"
        case let .list(list):
            let messages = list.compactMap(\.msg).joined(separator: "; ")
            return "HTTP \(response.statusCode): \(messages)"
        case let .text(text):
            return "HTTP \(response.statusCode): \(text)"
        case nil:
            return "HTTP \(response.statusCode): \(fallback)"
        }
    }
}
