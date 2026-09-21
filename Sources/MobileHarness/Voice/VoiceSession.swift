import AVFoundation
import Foundation

/// The configuration of a ``VoiceSession``.
public struct VoiceConfiguration: Sendable {
    /// The ElevenLabs API key.
    public var elevenLabsAPIKey: String
    /// The voice identifier used for the agent's speech.
    public var voiceID: String
    /// The speech synthesis model.
    public var speechModel: SpeechModel
    /// The delivery settings of the agent's speech.
    public var speechSettings: VoiceSettings
    /// The audio format of synthesized speech.
    public var outputFormat: AudioOutputFormat
    /// The speech recognition model.
    public var recognitionModel: SpeechRecognitionModel
    /// An ISO 639-1 language hint for recognition, or `nil` to auto-detect.
    public var recognitionLanguageCode: String?
    /// Utterance boundary detection tuning; `nil` disables the continuous call
    /// loop's automatic turn taking in favor of ``VoiceSession/listenOnce()``.
    public var utteranceDetection: UtteranceDetector.Configuration?
    /// Overrides the ElevenLabs API base URL; used by tests.
    public var baseURL: URL
    /// Overrides the HTTP transport; used by tests.
    public var transport: (any HTTPTransport)?

    /// Creates a voice configuration.
    public init(
        elevenLabsAPIKey: String,
        voiceID: String = ElevenLabsClient.defaultVoiceID,
        speechModel: SpeechModel = .multilingualV2,
        speechSettings: VoiceSettings = VoiceSettings(),
        outputFormat: AudioOutputFormat = .mp3_44100_128,
        recognitionModel: SpeechRecognitionModel = .scribeV1,
        recognitionLanguageCode: String? = nil,
        utteranceDetection: UtteranceDetector.Configuration? = UtteranceDetector.Configuration(),
        baseURL: URL = ElevenLabsClient.defaultBaseURL,
        transport: (any HTTPTransport)? = nil
    ) {
        self.elevenLabsAPIKey = elevenLabsAPIKey
        self.voiceID = voiceID
        self.speechModel = speechModel
        self.speechSettings = speechSettings
        self.outputFormat = outputFormat
        self.recognitionModel = recognitionModel
        self.recognitionLanguageCode = recognitionLanguageCode
        self.utteranceDetection = utteranceDetection
        self.baseURL = baseURL
        self.transport = transport
    }
}

/// The phases of a ``VoiceSession`` call.
public enum VoiceCallState: String, Sendable, Hashable {
    /// The session is not in a call.
    case idle
    /// The session is listening for speech.
    case listening
    /// The session is transcribing recorded speech.
    case transcribing
    /// The agent is thinking — running the model and any tools.
    case thinking
    /// The session is speaking the agent's answer.
    case speaking
}

/// A continuous voice call with an ``Agent``, powered by ElevenLabs.
///
/// The call loop is *speak → listen → transcribe → think → answer*:
/// ``MicrophoneRecorder`` captures one utterance, ElevenLabs Scribe transcribes
/// it, the agent runs — executing tools across as many stages as the task
/// needs — and ElevenLabs speaks the answer back. The loop repeats until
/// ``stop()``.
///
/// ```swift
/// let session = agent.makeVoiceSession(configuration: .init(
///     elevenLabsAPIKey: elevenLabsKey,
///     voiceID: "21m00Tcm4TlvDq8ikWAM"
/// ))
/// session.onStateChange = { state in /* drive call UI */ }
/// try await session.start()
/// // … later
/// await session.stop()
/// ```
///
/// For custom turn-taking, skip ``start()`` and compose the building blocks
/// ``listenOnce()``, ``ask(_:)``, and ``say(_:)`` yourself.
///
/// The *host application* must hold microphone permission before the first
/// recording; see ``MicrophoneRecorder``.
public actor VoiceSession {
    private let agent: Agent
    private let configuration: VoiceConfiguration
    private let client: ElevenLabsClient
    private let player = SpeechPlayer()
    private let recorder = MicrophoneRecorder()
    private var callTask: Task<Void, Never>?

    /// The current phase of the call.
    public private(set) var state: VoiceCallState = .idle

    /// Why the last call ended, when it ended in an error.
    public private(set) var lastErrorDescription: String?

    /// Observes call phase changes, delivered on a cooperative thread.
    public var onStateChange: (@Sendable (VoiceCallState) -> Void)?

    /// Creates a session around the given agent.
    public init(agent: Agent, configuration: VoiceConfiguration) {
        self.agent = agent
        self.configuration = configuration
        self.client = ElevenLabsClient(
            apiKey: configuration.elevenLabsAPIKey,
            baseURL: configuration.baseURL,
            transport: configuration.transport
        )
    }

    /// Creates a session around the given agent with an ElevenLabs key.
    public init(agent: Agent, elevenLabsAPIKey: String) {
        self.init(agent: agent, configuration: VoiceConfiguration(elevenLabsAPIKey: elevenLabsAPIKey))
    }

    /// Starts the continuous call loop.
    ///
    /// The loop runs in the background until ``stop()`` or an error ends it;
    /// errors are recorded in ``lastErrorDescription`` rather than thrown.
    /// Starting an already active call does nothing.
    ///
    /// - Throws: ``HarnessError/missingAPIKey(service:)`` when the ElevenLabs
    ///   key is empty, and ``HarnessError/recordingFailed(String)`` when no
    ///   microphone input is available.
    public func start() async throws {
        guard callTask == nil else { return }
        guard !configuration.elevenLabsAPIKey.isEmpty else {
            throw HarnessError.missingAPIKey(service: "ElevenLabs")
        }
        guard configuration.utteranceDetection != nil else {
            throw HarnessError.recordingFailed(
                "The call loop needs utterance detection; set VoiceConfiguration.utteranceDetection or drive the session manually."
            )
        }
        lastErrorDescription = nil
        configureAudioSession()
        callTask = Task { await runCallLoop() }
    }

    /// Ends the active call, cutting off any audio mid-flight.
    public func stop() async {
        callTask?.cancel()
        callTask = nil
        await player.stop()
        await recorder.cancelRecording()
        transition(to: .idle)
    }

    /// Whether the call loop is running.
    public var isActive: Bool {
        callTask != nil
    }

    // MARK: - Building blocks

    /// Records one utterance and returns its transcript.
    ///
    /// A building block for custom interfaces; the call loop uses it
    /// internally.
    /// - Throws: ``HarnessError`` from recording or transcription.
    public func listenOnce() async throws -> String {
        configureAudioSession()
        let recording = try await recorder.recordUtterance(
            detection: configuration.utteranceDetection ?? UtteranceDetector.Configuration()
        )
        let transcription = try await client.transcribeSpeech(
            in: recording,
            model: configuration.recognitionModel,
            languageCode: configuration.recognitionLanguageCode
        )
        return transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs the agent on spoken text and speaks the answer aloud.
    ///
    /// A building block for custom interfaces; the call loop uses it
    /// internally.
    /// - Returns: The agent's full response, including tool stages and usage.
    @discardableResult
    public func ask(_ text: String) async throws -> AgentResponse {
        let response = try await agent.run(text)
        try await speak(response.text)
        return response
    }

    /// Synthesizes and plays text without involving the agent.
    public func say(_ text: String) async throws {
        try await speak(text)
    }

    // MARK: - Call loop

    private func runCallLoop() async {
        while !Task.isCancelled {
            do {
                transition(to: .listening)
                let spoken = try await listenOnce()
                try Task.checkCancellation()
                guard !spoken.isEmpty else { continue }

                transition(to: .thinking)
                let response = try await agent.run(spoken)
                try Task.checkCancellation()

                transition(to: .speaking)
                try await speak(response.text)
            } catch is CancellationError {
                break
            } catch {
                lastErrorDescription = String(describing: error)
                break
            }
        }
        callTask = nil
        transition(to: .idle)
    }

    /// Synthesizes `text` with ElevenLabs and plays it to completion.
    private func speak(_ text: String) async throws {
        guard !text.isEmpty else { return }
        let audio = try await client.synthesizeSpeech(
            from: text,
            voiceID: configuration.voiceID,
            model: configuration.speechModel,
            settings: configuration.speechSettings,
            outputFormat: configuration.outputFormat
        )
        try await player.play(audio)
    }

    private func transition(to newState: VoiceCallState) {
        state = newState
        onStateChange?(newState)
    }

    /// Puts the shared audio session into voice-chat mode on iOS so recording
    /// and playback share the route; a no-op on macOS.
    private func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            // A category failure is non-fatal: the engine may still run with
            // the inherited session configuration.
        }
        #endif
    }
}
