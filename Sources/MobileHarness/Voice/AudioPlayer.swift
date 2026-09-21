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
    /// - Throws: ``HarnessError/playbackFailed(String)`` when the audio cannot
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
