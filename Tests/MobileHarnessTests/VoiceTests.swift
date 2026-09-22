import Foundation
import Testing
@testable import MobileHarness

@Suite("ElevenLabs client")
struct ElevenLabsClientTests {
    static let key = "xi-test-key"

    @Test("synthesizeSpeech sends the exact TTS request")
    func ttsRequest() async throws {
        let transport = MockTransport(responding: [HTTPResponse(statusCode: 200, body: Data([0x00, 0x01, 0x02]))])
        let client = ElevenLabsClient(apiKey: Self.key, transport: transport)
        let audio = try await client.synthesizeSpeech(
            from: "Hello there",
            voiceID: "voice-123",
            model: .turboV2_5,
            settings: VoiceSettings(stability: 0.7, similarityBoost: 0.9, style: 0.2, useSpeakerBoost: false, speed: 1.2),
            outputFormat: .mp3_44100_64
        )
        #expect(audio == Data([0x00, 0x01, 0x02]))

        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/voice-123?output_format=mp3_44100_64")
        #expect(request.headers["xi-api-key"] == Self.key)
        #expect(request.headers["Content-Type"] == "application/json")

        let body = try JSONDecoder().decode(JSONValue.self, from: #require(request.body))
        #expect(body["text"]?.stringValue == "Hello there")
        #expect(body["model_id"]?.stringValue == "eleven_turbo_v2_5")
        let settings = try #require(body["voice_settings"])
        #expect(settings["stability"]?.doubleValue == 0.7)
        #expect(settings["similarity_boost"]?.doubleValue == 0.9)
        #expect(settings["style"]?.doubleValue == 0.2)
        #expect(settings["use_speaker_boost"]?.boolValue == false)
        #expect(settings["speed"]?.doubleValue == 1.2)
    }

    @Test("streamSpeech uses the /stream endpoint and delivers chunks")
    func streamTTS() async throws {
        let transport = MockTransport(responding: [
            HTTPResponse(statusCode: 200, body: Data([0x00, 0x01, 0x02, 0x03]))
        ])
        let client = ElevenLabsClient(apiKey: Self.key, transport: transport)
        let chunks = try await client.streamSpeech(
            from: "Hello there",
            voiceID: "voice-123",
            model: .flashV2_5,
            outputFormat: .pcm_24000
        )
        var received = Data()
        for try await chunk in chunks {
            received.append(chunk)
        }
        #expect(received == Data([0x00, 0x01, 0x02, 0x03]))

        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://api.elevenlabs.io/v1/text-to-speech/voice-123/stream?output_format=pcm_24000")
        #expect(request.headers["xi-api-key"] == Self.key)
    }

    @Test("streamSpeech maps service errors before any audio arrives")
    func streamTTSError() async throws {
        let transport = MockTransport(responding: [
            HTTPResponse(
                statusCode: 401,
                body: Data(#"{"detail": {"status": "invalid_api_key", "message": "Invalid API key"}}"#.utf8)
            )
        ])
        let client = ElevenLabsClient(apiKey: Self.key, transport: transport)
        await #expect(throws: HarnessError.self) {
            _ = try await client.streamSpeech(from: "hi", outputFormat: .pcm_24000)
        }
    }

    @Test("PCM bytes convert to normalized float samples")
    func pcmConversion() {
        // Int16 samples: 0, 32767, -32768 — little-endian bytes.
        let data = Data([
            0x00, 0x00,       // 0
            0xFF, 0x7F,       // 32767
            0x00, 0x80,       // -32768
        ])
        let samples = StreamingSpeechPlayer.floatSamples(fromLittleEndianInt16: data)
        #expect(samples.count == 3)
        #expect(samples[0] == 0)
        #expect(abs(samples[1] - 1.0) < 0.0001)
        #expect(abs(samples[2] + 1.0) < 0.0001)
        #expect(StreamingSpeechPlayer.floatSamples(fromLittleEndianInt16: Data([0x01])).isEmpty)
    }

    @Test("transcribeSpeech sends a well-formed multipart body")
    func sttRequest() async throws {
        let responseBody = """
        {"language_code": "en", "language_probability": 0.98, "text": "Hello agent!"}
        """
        let transport = MockTransport(responding: [
            HTTPResponse(statusCode: 200, body: Data(responseBody.utf8)),
        ])
        let client = ElevenLabsClient(apiKey: Self.key, transport: transport)
        let transcription = try await client.transcribeSpeech(
            in: AudioRecording(data: Data([0xAA, 0xBB]), filename: "recording.m4a", mimeType: "audio/m4a"),
            model: .scribeV1,
            languageCode: "en"
        )
        #expect(transcription.text == "Hello agent!")
        #expect(transcription.languageCode == "en")
        #expect(transcription.languageProbability == 0.98)

        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
        #expect(request.headers["xi-api-key"] == Self.key)

        let contentType = try #require(request.headers["Content-Type"])
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentValueAfter(contentType, "boundary="))
        let body = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(body.hasPrefix("--\(boundary)\r\n"))

        // Form fields in order: model_id, language_code, then the file.
        #expect(body.contains("Content-Disposition: form-data; name=\"model_id\"\r\n\r\nscribe_v1\r\n"))
        #expect(body.contains("Content-Disposition: form-data; name=\"language_code\"\r\n\r\nen\r\n"))
        #expect(body.contains("Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n"))
        #expect(body.contains("Content-Type: audio/m4a\r\n\r\n"))
        #expect(body.contains(String(decoding: Data([0xAA, 0xBB]), as: UTF8.self)))
        #expect(body.hasSuffix("--\(boundary)--\r\n"))
    }

    @Test("listVoices decodes the voice library")
    func voices() async throws {
        let body = """
        {"voices": [
          {"voice_id": "v1", "name": "Rachel", "category": "premade"},
          {"voice_id": "v2", "name": "Custom", "category": "cloned"}
        ]}
        """
        let transport = MockTransport(responding: [HTTPResponse(statusCode: 200, body: Data(body.utf8))])
        let client = ElevenLabsClient(apiKey: Self.key, transport: transport)
        let voices = try await client.listVoices()
        #expect(voices.map(\.id) == ["v1", "v2"])
        #expect(voices.first?.name == "Rachel")
        #expect(voices.first?.category == "premade")
    }

    @Test("Service errors map the object detail shape")
    func objectDetailError() async throws {
        let transport = MockTransport(responding: [
            HTTPResponse(
                statusCode: 401,
                body: Data(#"{"detail": {"message": "Invalid API key", "status": "failed"}}"#.utf8)
            ),
        ])
        let client = ElevenLabsClient(apiKey: "bad", transport: transport)
        do {
            _ = try await client.synthesizeSpeech(from: "hi")
            Issue.record("Expected an error")
        } catch let error as HarnessError {
            guard case let .speechSynthesisFailed(message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message.contains("401"))
            #expect(message.contains("Invalid API key"))
        }
    }

    @Test("Validation errors map the list detail shape")
    func listDetailError() async throws {
        let transport = MockTransport(responding: [
            HTTPResponse(
                statusCode: 422,
                body: Data(#"{"detail": [{"loc": ["body", "text"], "msg": "field required", "type": "value_error"}]}"#.utf8)
            ),
        ])
        let client = ElevenLabsClient(apiKey: Self.key, transport: transport)
        do {
            _ = try await client.transcribeSpeech(in: .m4a(Data([0x00])))
            Issue.record("Expected an error")
        } catch let error as HarnessError {
            guard case let .transcriptionFailed(message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message.contains("field required"))
        }
    }

    @Test("Missing keys fail fast without a request")
    func missingKey() async throws {
        let client = ElevenLabsClient(apiKey: "", transport: MockTransport(responding: []))
        await #expect(throws: HarnessError.missingAPIKey(service: "ElevenLabs")) {
            _ = try await client.synthesizeSpeech(from: "hi")
        }
        await #expect(throws: HarnessError.missingAPIKey(service: "ElevenLabs")) {
            _ = try await client.transcribeSpeech(in: .m4a(Data([0x00])))
        }
        await #expect(throws: HarnessError.missingAPIKey(service: "ElevenLabs")) {
            _ = try await client.listVoices()
        }
    }

    @Test("Empty inputs are rejected")
    func emptyInputs() async throws {
        let client = ElevenLabsClient(apiKey: Self.key, transport: MockTransport(responding: []))
        do {
            _ = try await client.synthesizeSpeech(from: "")
            Issue.record("Expected an error")
        } catch let error as HarnessError {
            guard case .speechSynthesisFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        do {
            _ = try await client.transcribeSpeech(in: .m4a(Data()))
            Issue.record("Expected an error")
        } catch let error as HarnessError {
            guard case .transcriptionFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }
}

private func contentValueAfter(_ text: String, _ marker: String) -> Substring {
    guard let range = text.range(of: marker) else { return "" }
    return text[range.upperBound...]
}

@Suite("VoiceSession building blocks")
struct VoiceSessionTests {
    @Test("ask runs the agent and speaks the reply through the transport")
    func askRoundTrip() async throws {
        let transport = MockTransport(routing: { request in
            switch (request.method, request.url.path) {
            case ("POST", "/v1/chat/completions"):
                return Fixtures.completion(text: "It is sunny.")
            case ("POST", "/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM"):
                return HTTPResponse(statusCode: 200, body: Data("audio".utf8))
            default:
                throw HarnessError.invalidResponse("Unexpected \(request.method) \(request.url)")
            }
        })
        // Point OpenRouter requests at the ElevenLabs-shaped mock too.
        let agent = Agent(configuration: AgentConfiguration(
            openRouterAPIKey: "or-key",
            openRouterBaseURL: URL(string: "https://api.elevenlabs.io/v1")!,
            transport: transport
        ))
        let session = VoiceSession(
            agent: agent,
            configuration: VoiceConfiguration(
                elevenLabsAPIKey: "xi-key",
                transport: transport
            )
        )
        // The mock's audio bytes are not decodable, so playback fails at the
        // very end — after the agent run, an optional pricing lookup (the
        // fixture carries no cost), and the synthesis request.
        do {
            _ = try await session.ask("How is the weather?")
            Issue.record("Expected a playback failure on undecodable mock audio")
        } catch let error as HarnessError {
            guard case .playbackFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        #expect(transport.requests.count == 3)
        #expect(transport.requests[0].url.path.hasSuffix("/chat/completions"))
        #expect(transport.requests[1].url.path.hasSuffix("/models"))
        #expect(transport.requests[2].url.path.hasSuffix("/text-to-speech/21m00Tcm4TlvDq8ikWAM"))

        let states = await session.state
        #expect(states == .idle)
    }

    @Test("onAnswerAudioStarted fires once, right before answer playback")
    func answerAudioCallback() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            var count: Int {
                lock.lock(); defer { lock.unlock() }
                return value
            }
            func increment() {
                lock.lock(); value += 1; lock.unlock()
            }
        }
        let counter = Counter()
        let transport = MockTransport(routing: { request in
            switch (request.method, request.url.path) {
            case ("POST", "/v1/chat/completions"):
                return Fixtures.completion(text: "It is sunny.")
            case ("POST", "/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM"):
                return HTTPResponse(statusCode: 200, body: Data("audio".utf8))
            default:
                throw HarnessError.invalidResponse("Unexpected \(request.method) \(request.url)")
            }
        })
        let agent = Agent(configuration: AgentConfiguration(
            openRouterAPIKey: "or-key",
            openRouterBaseURL: URL(string: "https://api.elevenlabs.io/v1")!,
            transport: transport
        ))
        let session = VoiceSession(
            agent: agent,
            configuration: VoiceConfiguration(
                elevenLabsAPIKey: "xi-key",
                transport: transport
            )
        )
        session.onAnswerAudioStarted = { counter.increment() }
        do {
            _ = try await session.ask("How is the weather?")
        } catch let error as HarnessError {
            // Undecodable mock audio fails playback — after the callback fired.
            guard case .playbackFailed = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
        #expect(counter.count == 1)
    }

    @Test("start with a missing key fails fast")
    func missingKeyOnStart() async throws {
        let agent = Agent(openRouterAPIKey: "or-key")
        let session = VoiceSession(agent: agent, elevenLabsAPIKey: "")
        await #expect(throws: HarnessError.missingAPIKey(service: "ElevenLabs")) {
            try await session.start()
        }
    }
}

@Suite("Utterance detector")
struct UtteranceDetectorTests {
    @Test("Silence followed by speech followed by silence produces one utterance")
    func basicUtterance() {
        var detector = UtteranceDetector()
        // Silence before speech.
        #expect(detector.process(rms: 0.001, at: 0.1) == nil)
        #expect(detector.process(rms: 0.002, at: 0.2) == nil)
        // Speech starts.
        #expect(detector.process(rms: 0.05, at: 0.3) == .utteranceStarted(at: 0.3))
        // Speech continues above the end threshold; no event.
        #expect(detector.process(rms: 0.03, at: 1.5) == nil)
        #expect(detector.process(rms: 0.02, at: 2.0) == nil)
        // Trailing silence, shorter than the silence window.
        #expect(detector.process(rms: 0.001, at: 2.5) == nil)
        // One full second of trailing silence ends the utterance.
        #expect(detector.process(rms: 0.001, at: 3.5) == .utteranceEnded(at: 3.5))
    }

    @Test("Blips shorter than the minimum duration are discarded")
    func shortBlipsDiscarded() {
        var detector = UtteranceDetector()
        #expect(detector.process(rms: 0.1, at: 0.0) == .utteranceStarted(at: 0.0))
        // Quiet for over a second after only 0.1s of speech — discarded.
        #expect(detector.process(rms: 0.001, at: 1.2) == nil)
        // The next real utterance still detects.
        #expect(detector.process(rms: 0.1, at: 2.0) == .utteranceStarted(at: 2.0))
        #expect(detector.process(rms: 0.1, at: 2.5) == nil)
        #expect(detector.process(rms: 0.001, at: 3.6) == .utteranceEnded(at: 3.6))
    }

    @Test("Continuous speech is capped at the maximum duration")
    func maximumCap() {
        var detector = UtteranceDetector(configuration: .init(maximumDuration: 10))
        #expect(detector.process(rms: 0.2, at: 0) == .utteranceStarted(at: 0))
        #expect(detector.process(rms: 0.2, at: 9.9) == nil)
        #expect(detector.process(rms: 0.2, at: 10.1) == .utteranceEnded(at: 10.1))
    }

    @Test("Hysteresis keeps moderate audio inside an utterance")
    func hysteresis() {
        var detector = UtteranceDetector()
        #expect(detector.process(rms: 0.05, at: 0) == .utteranceStarted(at: 0))
        // Between end and start thresholds: silence timer runs only below end.
        #expect(detector.process(rms: 0.015, at: 0.5) == nil)
        #expect(detector.process(rms: 0.015, at: 0.9) == nil)
        // Still inside silence window — no end.
        #expect(detector.process(rms: 0.001, at: 1.2) == nil)
        #expect(detector.process(rms: 0.001, at: 2.0) == .utteranceEnded(at: 2.0))
    }
}

@Suite("SpeechPlayer")
struct SpeechPlayerTests {
    @Test("Empty audio throws playbackFailed without touching the hardware")
    func invalidAudio() async throws {
        let player = SpeechPlayer()
        await #expect(throws: HarnessError.self) {
            try await player.play(Data())
        }
        let playing = await player.isPlaying
        #expect(!playing)
    }
}
