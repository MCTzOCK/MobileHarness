# Voice calling

@Metadata {
    @PageImage(purpose: card, source: "voice-calling", alt: "A sound wave traveling between a person and a phone")
    @PageColor(purple)
}

A ``VoiceSession`` turns any ``Agent`` into a hands-free voice assistant: it listens with ``MicrophoneRecorder``, transcribes with ElevenLabs Scribe, runs the agent — tools included — and speaks the answer with ElevenLabs voices.

## Set up permissions first

The **host app** owns microphone permission. Add to your `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This assistant needs the microphone to hear your requests.</string>
```

Then request access before the first recording (iOS):

```swift
import AVFAudio

let granted = await withCheckedContinuation { continuation in
    AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
    }
}
guard granted else { /* explain and bail out */ }
```

## Start a call

```swift
let session = agent.makeVoiceSession(configuration: .init(
    elevenLabsAPIKey: elevenLabsKey,
    voiceID: "21m00Tcm4TlvDq8ikWAM",      // "Rachel"; see listVoices()
    recognitionLanguageCode: "en"          // or nil to auto-detect
))
session.onStateChange = { state in
    // idle, listening, transcribing, thinking, speaking
}
try await session.start()
```

The call loops *listen → transcribe → think → speak* until ``VoiceSession/stop()``. Errors end the call and land in ``VoiceSession/lastErrorDescription``.

## Turn taking

Turn boundaries come from ``UtteranceDetector``: speech starts when the microphone's RMS level crosses a threshold, and an utterance ends after about a second of trailing silence (tune every boundary in ``UtteranceDetector/Configuration``):

```swift
var configuration = VoiceConfiguration(elevenLabsAPIKey: key)
configuration.utteranceDetection = .init(
    startThreshold: 0.03,      // quieter environments: lower this
    silenceDuration: 0.8       // snappier turns: shorten this
)
```

## Build your own flow

Skip ``VoiceSession/start()`` and compose the building blocks — for a push-to-talk button, or to show transcripts in your UI:

```swift
// Press to talk: record one utterance and read the transcript.
let heard = try await session.listenOnce()

// Ask by text and hear the answer (returns the full AgentResponse).
let response = try await session.ask("What's on my calendar?")

// Speak any text without involving the agent.
try await session.say("Reminder set for 5 PM.")
```

## Choosing a voice

List the account's voices and pick one:

```swift
let client = ElevenLabsClient(apiKey: elevenLabsKey)
for voice in try await client.listVoices() {
    print(voice.id, voice.name ?? "", voice.category ?? "")
}
```

Speech latency matters in a conversation — ``SpeechModel/turboV2_5`` and ``SpeechModel/flashV2_5`` trade a little quality for much faster first audio:

```swift
var configuration = VoiceConfiguration(elevenLabsAPIKey: key)
configuration.speechModel = .turboV2_5
```
