import AVFoundation
import Foundation

/// A pure state machine that detects utterance boundaries from audio loudness.
///
/// Feed it the root-mean-square level of each audio buffer with a monotonic
/// timestamp; it reports when an utterance starts and, after trailing silence,
/// when it ends. The detector is a value type so its logic is unit-testable
/// without audio hardware.
public struct UtteranceDetector: Sendable {
    /// Tuning of an ``UtteranceDetector``.
    public struct Configuration: Sendable, Hashable {
        /// The RMS level at or above which an utterance starts.
        public var startThreshold: Double
        /// The RMS level below which audio counts as silence.
        ///
        /// Deliberately below `startThreshold` (hysteresis) so speech does not
        /// flicker on and off around one boundary.
        public var endThreshold: Double
        /// The trailing silence that ends an utterance.
        public var silenceDuration: TimeInterval
        /// Utterances shorter than this are discarded as noise.
        public var minimumDuration: TimeInterval
        /// The hard cap after which an utterance ends even without silence.
        public var maximumDuration: TimeInterval

        /// Creates a detector configuration.
        public init(
            startThreshold: Double = 0.02,
            endThreshold: Double = 0.008,
            silenceDuration: TimeInterval = 1.0,
            minimumDuration: TimeInterval = 0.25,
            maximumDuration: TimeInterval = 30
        ) {
            self.startThreshold = startThreshold
            self.endThreshold = endThreshold
            self.silenceDuration = silenceDuration
            self.minimumDuration = minimumDuration
            self.maximumDuration = maximumDuration
        }
    }

    /// A detector decision for one processed buffer.
    public enum Event: Sendable, Hashable {
        /// Speech began at the given timestamp.
        case utteranceStarted(at: TimeInterval)
        /// A complete utterance ended at the given timestamp.
        case utteranceEnded(at: TimeInterval)
    }

    private let configuration: Configuration
    private var hasSpeech = false
    private var speechStart: TimeInterval = 0
    private var lastSound: TimeInterval = 0

    /// Creates a detector with the given configuration.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Processes one buffer's RMS level and returns any resulting event.
    ///
    /// - Parameters:
    ///   - rms: The root-mean-square level of the buffer, between 0 and 1.
    ///   - timestamp: A monotonic timestamp for the buffer, in seconds.
    public mutating func process(rms: Double, at timestamp: TimeInterval) -> Event? {
        if !hasSpeech {
            guard rms >= configuration.startThreshold else { return nil }
            hasSpeech = true
            speechStart = timestamp
            lastSound = timestamp
            return .utteranceStarted(at: timestamp)
        }
        if rms >= configuration.endThreshold {
            lastSound = timestamp
        }
        if timestamp - speechStart >= configuration.maximumDuration {
            hasSpeech = false
            return .utteranceEnded(at: timestamp)
        }
        guard timestamp - lastSound >= configuration.silenceDuration else { return nil }
        hasSpeech = false
        // Judge the utterance by how long speech actually lasted, excluding
        // the trailing silence that triggered this check.
        if lastSound - speechStart >= configuration.minimumDuration {
            return .utteranceEnded(at: timestamp)
        }
        return nil
    }
}

/// Records microphone audio as AAC-in-MP4 clips.
///
/// ``recordUtterance()`` records exactly one utterance using
/// ``UtteranceDetector``; ``record()`` and ``stop()`` give manual control for
/// push-to-talk interfaces. Clips are encoded to `.m4a` and wrapped in
/// ``AudioRecording`` for ``ElevenLabsClient/transcribeSpeech(in:model:languageCode:)``.
///
/// The *host application* is responsible for microphone permission — add
/// `NSMicrophoneUsageDescription` to the app's information property list and
/// request access before recording; iOS exposes this via
/// `AVAudioApplication.requestRecordPermission`.
public actor MicrophoneRecorder {
    /// The hard cap on manually controlled recordings, bounding memory use.
    private static let manualRecordingCap: TimeInterval = 120

    private let engine = AVAudioEngine()
    private var detector: UtteranceDetector?
    private var sampleRate: Double = 0
    private var recordingStart: TimeInterval = 0
    private var monoSamples: [Float] = []
    private var continuation: CheckedContinuation<AudioRecording, Error>?

    /// Whether a recording is currently running.
    public private(set) var isRecording = false

    /// Creates a recorder.
    public init() {}

    /// Records the next utterance, returning when its trailing silence ends.
    ///
    /// Utterance boundaries come from ``UtteranceDetector`` with the given
    /// configuration. Cancelling the awaiting task stops the microphone and
    /// throws `CancellationError`.
    ///
    /// - Throws: ``HarnessError/recordingFailed(String)`` when no input is
    ///   available, and `CancellationError` when cancelled.
    public func recordUtterance(
        detection configuration: UtteranceDetector.Configuration = UtteranceDetector.Configuration()
    ) async throws -> AudioRecording {
        try await withTaskCancellationHandler {
            try startRecording(detector: UtteranceDetector(configuration: configuration))
            return try await withCheckedThrowingContinuation { config in
                continuation = config
            }
        } onCancel: {
            Task { await self.cancelRecording() }
        }
    }

    /// Starts recording with no automatic stop.
    ///
    /// - Throws: ``HarnessError/recordingFailed(String)`` when no input is
    ///   available or a recording is already running.
    public func record() async throws {
        guard !isRecording else {
            throw HarnessError.recordingFailed("A recording is already running.")
        }
        try startRecording(detector: nil)
    }

    /// Stops recording started with ``record()`` and returns the clip.
    ///
    /// - Throws: ``HarnessError/recordingFailed(String)`` when nothing is being
    ///   recorded or encoding the clip fails.
    public func stop() async throws -> AudioRecording {
        guard isRecording else {
            throw HarnessError.recordingFailed("No recording is running.")
        }
        return try finishRecording()
    }

    /// Stops any active recording and fails its awaiting caller with
    /// `CancellationError`.
    public func cancelRecording() {
        guard isRecording else { return }
        tearDownTap()
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }

    // MARK: - Recording lifecycle

    private func startRecording(detector newDetector: UtteranceDetector?) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw HarnessError.recordingFailed(
                "No microphone input is available. Check microphone permission and that an input device is connected."
            )
        }

        detector = newDetector
        sampleRate = format.sampleRate
        recordingStart = CACurrentMediaTime()
        monoSamples = []
        isRecording = true

        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let chunk = Self.monoChunk(from: buffer)
            Task { await self.process(samples: chunk.samples, rootMeanSquare: chunk.rootMeanSquare) }
        }
        do {
            try engine.start()
        } catch {
            tearDownTap()
            isRecording = false
            throw HarnessError.recordingFailed("Starting the audio engine failed: \(error)")
        }
    }

    /// Appends one chunk of audio, applies utterance detection, and ends the
    /// recording when its boundary condition is met.
    private func process(samples: [Float], rootMeanSquare: Double) {
        guard isRecording else { return }
        monoSamples.append(contentsOf: samples)
        let elapsed = CACurrentMediaTime() - recordingStart

        var shouldFinish = false
        if detector != nil,
           let event = detector?.process(rms: rootMeanSquare, at: elapsed),
           case .utteranceEnded = event {
            shouldFinish = true
        } else if detector == nil {
            shouldFinish = elapsed >= Self.manualRecordingCap
        }
        guard shouldFinish else { return }

        let pending = continuation
        continuation = nil
        do {
            pending?.resume(returning: try finishRecording())
        } catch {
            pending?.resume(throwing: error)
        }
    }

    /// Stops the tap and engine and returns the encoded clip.
    private func finishRecording() throws -> AudioRecording {
        tearDownTap()
        isRecording = false
        let samples = monoSamples
        let rate = sampleRate
        return try Self.encode(monoSamples: samples, sampleRate: rate)
    }

    /// Stops the input tap and the engine.
    private func tearDownTap() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
    }

    // MARK: - Conversion

    /// A downmixed mono audio chunk from one input-tap buffer.
    private struct MonoChunk: Sendable {
        var samples: [Float]
        var rootMeanSquare: Double
    }

    /// Extracts one downmixed mono chunk from an input-tap buffer.
    ///
    /// Only non-interleaved Float32 input is converted — the format input taps
    /// use on Apple platforms; anything else yields an empty chunk.
    ///
    /// - Complexity: O(*n*), where *n* is the buffer's frame count.
    nonisolated private static func monoChunk(from buffer: AVAudioPCMBuffer) -> MonoChunk {
        let frames = Int(buffer.frameLength)
        guard frames > 0,
              buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              let channels = buffer.floatChannelData
        else {
            return MonoChunk(samples: [], rootMeanSquare: 0)
        }
        let channelCount = Int(buffer.format.channelCount)
        var samples = [Float](repeating: 0, count: frames)
        var sum: Float = 0
        for channel in 0..<channelCount {
            let data = channels[channel]
            for frame in 0..<frames {
                let sample = data[frame]
                samples[frame] += sample
            }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for frame in 0..<frames {
                samples[frame] *= scale
            }
        }
        for sample in samples {
            sum += sample * sample
        }
        return MonoChunk(samples: samples, rootMeanSquare: Double((sum / Float(frames)).squareRoot()))
    }

    /// Encodes mono Float32 samples as an AAC-in-MP4 clip.
    nonisolated private static func encode(monoSamples: [Float], sampleRate: Double) throws -> AudioRecording {
        guard !monoSamples.isEmpty, sampleRate > 0 else {
            throw HarnessError.recordingFailed("The recording contains no audio.")
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw HarnessError.recordingFailed("Creating the audio format failed.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(monoSamples.count)) else {
            throw HarnessError.recordingFailed("Allocating the audio buffer failed.")
        }
        buffer.frameLength = AVAudioFrameCount(monoSamples.count)
        monoSamples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: monoSamples.count)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileHarness-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        } catch {
            throw HarnessError.recordingFailed("Encoding the recording failed: \(error)")
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw HarnessError.recordingFailed("Reading the encoded recording failed.")
        }
        return AudioRecording.m4a(data)
    }
}
