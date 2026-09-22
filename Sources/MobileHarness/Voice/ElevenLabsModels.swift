import Foundation

/// A text-to-speech model served by ElevenLabs.
///
/// The value wraps a wire identifier; the static members cover the standard
/// models and ``init(rawValue:)`` accepts any new one ElevenLabs ships.
public struct SpeechModel: Sendable, Hashable {
    /// The wire identifier, for example `"eleven_multilingual_v2"`.
    public let rawValue: String

    /// Creates a model reference from a raw identifier.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The default high-quality multilingual model.
    public static let multilingualV2 = SpeechModel(rawValue: "eleven_multilingual_v2")
    /// The low-latency turbo model tuned for realtime use.
    public static let turboV2_5 = SpeechModel(rawValue: "eleven_turbo_v2_5")
    /// The lowest-latency flash model.
    public static let flashV2_5 = SpeechModel(rawValue: "eleven_flash_v2_5")
    /// The expressive v3 model.
    public static let v3 = SpeechModel(rawValue: "eleven_v3")
}

/// A speech-to-text model served by ElevenLabs.
public struct SpeechRecognitionModel: Sendable, Hashable {
    /// The wire identifier, for example `"scribe_v1"`.
    public let rawValue: String

    /// Creates a recognition model reference from a raw identifier.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The original Scribe model.
    public static let scribeV1 = SpeechRecognitionModel(rawValue: "scribe_v1")
    /// The second-generation Scribe model.
    public static let scribeV2 = SpeechRecognitionModel(rawValue: "scribe_v2")
}

/// The delivery settings applied to synthesized speech.
public struct VoiceSettings: Sendable, Hashable {
    /// Voice stability — lower values add expressiveness, higher values add consistency.
    public var stability: Double
    /// How strongly the output mimics the original voice.
    public var similarityBoost: Double
    /// Style exaggeration of the original voice.
    public var style: Double
    /// Whether to boost similarity to the original speaker.
    public var useSpeakerBoost: Bool
    /// Playback speed multiplier around 1.0.
    public var speed: Double

    /// Creates voice settings.
    public init(
        stability: Double = 0.5,
        similarityBoost: Double = 0.75,
        style: Double = 0,
        useSpeakerBoost: Bool = true,
        speed: Double = 1
    ) {
        self.stability = stability
        self.similarityBoost = similarityBoost
        self.style = style
        self.useSpeakerBoost = useSpeakerBoost
        self.speed = speed
    }
}

/// The audio container format of synthesized speech.
public enum AudioOutputFormat: String, Sendable, Hashable, CaseIterable {
    /// MP3 at 44.1 kHz, 128 kbps — the default.
    case mp3_44100_128 = "mp3_44100_128"
    /// MP3 at 44.1 kHz, 96 kbps.
    case mp3_44100_96 = "mp3_44100_96"
    /// MP3 at 44.1 kHz, 64 kbps.
    case mp3_44100_64 = "mp3_44100_64"
    /// MP3 at 24 kHz, 48 kbps.
    case mp3_24000_48 = "mp3_24000_48"
    /// Opus at 48 kHz, 96 kbps.
    case opus_48000_96 = "opus_48000_96"
    /// Raw 16-bit little-endian mono PCM at 16 kHz — streamable chunk by
    /// chunk into ``StreamingSpeechPlayer``.
    case pcm_16000 = "pcm_16000"
    /// Raw 16-bit little-endian mono PCM at 24 kHz — streamable chunk by
    /// chunk into ``StreamingSpeechPlayer``.
    case pcm_24000 = "pcm_24000"
    /// Raw 16-bit little-endian mono PCM at 44.1 kHz — streamable chunk by
    /// chunk into ``StreamingSpeechPlayer``.
    case pcm_44100 = "pcm_44100"
    /// Uncompressed WAV at 16 kHz.
    case wav_16000 = "wav_16000"
    /// Uncompressed WAV at 44.1 kHz.
    case wav_44100 = "wav_44100"

    /// `true` for the raw PCM formats whose chunks play incrementally.
    public var isPCM: Bool {
        switch self {
        case .pcm_16000, .pcm_24000, .pcm_44100: true
        default: false
        }
    }

    /// The PCM sample rate in hertz, or `nil` for compressed containers.
    public var pcmSampleRate: Double? {
        switch self {
        case .pcm_16000: 16_000
        case .pcm_24000: 24_000
        case .pcm_44100: 44_100
        default: nil
        }
    }
}

/// An audio clip ready for transcription or playback.
public struct AudioRecording: Sendable, Hashable {
    /// The encoded audio bytes.
    public let data: Data
    /// The file name sent to speech-to-text services, including an extension.
    public let filename: String
    /// The MIME type of `data`, for example `"audio/m4a"`.
    public let mimeType: String

    /// Creates a recording.
    public init(data: Data, filename: String, mimeType: String) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
    }

    /// Wraps AAC-in-MP4 bytes — the format ``MicrophoneRecorder`` produces.
    public static func m4a(_ data: Data) -> AudioRecording {
        AudioRecording(data: data, filename: "recording.m4a", mimeType: "audio/m4a")
    }
}

/// The transcript of one audio clip.
public struct Transcription: Sendable, Hashable {
    /// The recognized text.
    public let text: String
    /// The detected ISO language code, for example `"en"`.
    public let languageCode: String?
    /// The detector's confidence in `languageCode`, between 0 and 1.
    public let languageProbability: Double?
}

/// A voice available to the ElevenLabs account.
public struct ElevenLabsVoice: Sendable, Hashable {
    /// The voice identifier used with ``ElevenLabsClient/synthesizeSpeech(from:voiceID:model:settings:outputFormat:)``.
    public let id: String
    /// The display name of the voice.
    public let name: String?
    /// The voice category, for example `"premade"` or `"cloned"`.
    public let category: String?
}

// MARK: - Wire payloads

struct SpeechRequestDTO: Encodable, Sendable {
    struct VoiceSettingsDTO: Encodable, Sendable {
        let stability: Double
        let similarityBoost: Double
        let style: Double
        let useSpeakerBoost: Bool
        let speed: Double

        enum CodingKeys: String, CodingKey {
            case stability
            case similarityBoost = "similarity_boost"
            case style
            case useSpeakerBoost = "use_speaker_boost"
            case speed
        }
    }

    let text: String
    let modelID: String
    let voiceSettings: VoiceSettingsDTO

    enum CodingKeys: String, CodingKey {
        case text
        case modelID = "model_id"
        case voiceSettings = "voice_settings"
    }
}

struct TranscriptionResponseDTO: Decodable, Sendable {
    let text: String?
    let languageCode: String?
    let languageProbability: Double?

    enum CodingKeys: String, CodingKey {
        case text
        case languageCode = "language_code"
        case languageProbability = "language_probability"
    }
}

struct VoiceListResponseDTO: Decodable, Sendable {
    struct VoiceDTO: Decodable, Sendable {
        let id: String?
        let name: String?
        let category: String?

        enum CodingKeys: String, CodingKey {
            case name, category
            case id = "voice_id"
        }
    }

    let voices: [VoiceDTO]
}
