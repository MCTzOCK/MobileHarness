import AVFoundation
import Foundation

/// Plays synthesized speech to completion.
///
/// ``VoiceSession`` uses this to speak agent answers. The actor serializes
/// playback: starting a new clip while one plays interrupts the old one
/// (barge-in), and ``stop()`` cuts audio immediately.
public actor SpeechPlayer {
    /// Bridges `AVAudioPlayerDelegate` callbacks back into the actor.
    ///
    /// The delegate protocol carries main-actor isolation in the SDK, so the
    /// initializer is nonisolated to let the actor hold the bridge as a stored
    /// default, and the callback slot is written before each `play()` begins.
    private final class Delegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        nonisolated(unsafe) var onFinish: (@Sendable (Bool) -> Void)?

        nonisolated override init() {
            super.init()
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            onFinish?(flag)
        }
    }

    private let delegate = Delegate()
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Error>?

    /// Whether audio is currently playing.
    public private(set) var isPlaying = false

    /// Creates a player.
    public init() {}

    /// Plays an audio clip and suspends until it finishes or is interrupted.
    ///
    /// - Parameter audio: Encoded audio, such as the MP3 bytes returned by
    ///   ``ElevenLabsClient/synthesizeSpeech(from:voiceID:model:settings:outputFormat:)``.
    /// - Throws: ``HarnessError/playbackFailed(_:)`` when the audio cannot
    ///   be decoded or finished unsuccessfully.
    public func play(_ audio: Data) async throws {
        guard !audio.isEmpty else {
            throw HarnessError.playbackFailed("The audio to play is empty.")
        }
        let newPlayer: AVAudioPlayer
        do {
            newPlayer = try AVAudioPlayer(data: audio)
        } catch {
            throw HarnessError.playbackFailed("Decoding the audio failed: \(error)")
        }
        guard newPlayer.duration > 0 else { return }

        // Barge in on any active playback before starting the new clip.
        if continuation != nil {
            stopPlayback()
        }

        return try await withCheckedThrowingContinuation { config in
            continuation = config
            delegate.onFinish = { @Sendable [weak self] successfully in
                guard let self else { return }
                Task { await self.playbackFinished(successfully: successfully) }
            }
            newPlayer.delegate = delegate
            player = newPlayer
            guard newPlayer.play() else {
                playbackFinished(successfully: false)
                return
            }
            isPlaying = true
        }
    }

    /// Stops any active playback, resuming a waiting ``play(_:)`` caller.
    public func stop() {
        stopPlayback()
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
        resumeContinuation(successfully: true)
    }

    private func playbackFinished(successfully: Bool) {
        player = nil
        isPlaying = false
        resumeContinuation(successfully: successfully)
    }

    /// Resumes the pending continuation exactly once.
    private func resumeContinuation(successfully: Bool) {
        guard let pending = continuation else { return }
        continuation = nil
        if successfully {
            pending.resume()
        } else {
            pending.resume(throwing: HarnessError.playbackFailed("Audio playback finished unsuccessfully."))
        }
    }
}

/// Plays a stream of raw PCM chunks as they arrive.
///
/// The companion to ``ElevenLabsClient/streamSpeech(from:voiceID:model:settings:outputFormat:)``:
/// call ``start(sampleRate:)`` once, ``append(_:)`` per chunk, and
/// ``finish()`` when the stream ends — audio starts playing with the first
/// chunk instead of waiting for the whole clip. ``stop()`` cuts playback
/// immediately (barge-in).
public actor StreamingSpeechPlayer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var started = false
    private var attached = false
    private var finished = false
    private var pendingBuffers = 0
    private var leftoverByte: UInt8?
    private var continuation: CheckedContinuation<Void, Error>?

    /// Whether audio has been scheduled and playback is underway.
    public private(set) var isPlaying = false

    /// Creates a player.
    public init() {}

    /// Prepares playback for raw 16-bit little-endian mono PCM chunks.
    ///
    /// One player serves one stream; create a new player per utterance.
    ///
    /// - Parameter sampleRate: The chunk stream's sample rate in hertz, for
    ///   example 24 000 for ``AudioOutputFormat/pcm_24000``.
    /// - Throws: ``HarnessError/playbackFailed(_:)`` when the audio engine
    ///   cannot be configured or started, or the player was already used.
    public func start(sampleRate: Double) throws {
        guard !started else { return }
        guard !finished else {
            throw HarnessError.playbackFailed("This player has already served a stream; create a new one.")
        }
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw HarnessError.playbackFailed("Creating the PCM playback format failed.")
        }
        if !attached {
            engine.attach(player)
            attached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
        do {
            try engine.start()
        } catch {
            throw HarnessError.playbackFailed("Starting the audio engine failed: \(error)")
        }
        player.play()
        format = pcmFormat
        started = true
    }

    /// Schedules one chunk of raw 16-bit little-endian mono PCM for playback.
    ///
    /// Chunks may split a sample in half; the leftover byte is carried into
    /// the next chunk.
    public func append(_ chunk: Data) throws {
        guard started, !finished else { return }
        var data = chunk
        if let leftover = leftoverByte {
            data = Data([leftover]) + data
            leftoverByte = nil
        }
        if data.count % 2 == 1 {
            leftoverByte = data.last
            data = data.dropLast()
        }
        let samples = Self.floatSamples(fromLittleEndianInt16: data)
        guard !samples.isEmpty, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        pendingBuffers += 1
        isPlaying = true
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            Task { await self.bufferFinished() }
        }
    }

    /// Marks the stream complete and suspends until every chunk has played.
    public func finish() async throws {
        guard started else { return }
        finished = true
        if pendingBuffers == 0 {
            stopEngine()
            return
        }
        try await withCheckedThrowingContinuation { config in
            continuation = config
        }
    }

    /// Stops playback immediately, resuming a waiting ``finish()``.
    public func stop() {
        guard started else { return }
        stopEngine()
        resumeContinuation(successfully: true)
    }

    // MARK: - Internals

    private func bufferFinished() {
        pendingBuffers = max(0, pendingBuffers - 1)
        if finished, pendingBuffers == 0 {
            stopEngine()
            resumeContinuation(successfully: true)
        }
    }

    private func stopEngine() {
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
        isPlaying = false
        pendingBuffers = 0
        started = false
        finished = true
    }

    /// Resumes the pending continuation exactly once.
    private func resumeContinuation(successfully: Bool) {
        guard let pending = continuation else { return }
        continuation = nil
        if successfully {
            pending.resume()
        } else {
            pending.resume(throwing: HarnessError.playbackFailed("Streamed playback finished unsuccessfully."))
        }
    }

    /// Converts raw little-endian Int16 bytes to normalized Float samples.
    static func floatSamples(fromLittleEndianInt16 data: Data) -> [Float] {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return [] }
        var samples = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in 0..<sampleCount {
                let offset = index * 2
                let low = UInt16(raw[offset])
                let high = UInt16(raw[offset + 1])
                let value = Int16(bitPattern: low | (high << 8))
                samples[index] = Float(value) / Float(Int16.max)
            }
        }
        return samples
    }
}
