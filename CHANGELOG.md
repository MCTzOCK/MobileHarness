# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `VoiceSession/onAnswerAudioStarted` — fires when answer audio actually
  starts playing (buffered playback start, or the first streamed chunk),
  later than the `speaking` state, which begins while synthesis is still on
  the wire. Both session callbacks are now stored `nonisolated(unsafe)` so
  the documented `session.onStateChange = { … }` assignment works from any
  isolation domain.
- **Streaming speech synthesis** — `ElevenLabsClient/streamSpeech(from:voiceID:model:settings:outputFormat:)`
  calls the `/text-to-speech/{id}/stream` endpoint and delivers audio chunks
  as ElevenLabs produces them. New raw PCM `AudioOutputFormat`s
  (`.pcm_16000`, `.pcm_24000`, `.pcm_44100`) pair with the new
  ``StreamingSpeechPlayer``, which plays chunks incrementally through
  `AVAudioEngine` — audio starts with the first chunk instead of after the
  whole clip. `VoiceConfiguration/streamSpeech` opts the call loop's answers
  into streamed playback (PCM output required).
- **Streaming HTTP transport** — `HTTPTransport/sendStreaming(_:)` returns an
  ``HTTPStreamingResponse`` with the body as an `AsyncThrowingStream<Data, Error>`;
  ``URLSessionTransport`` implements true chunked transfer via
  `URLSession.bytes`, and a protocol default buffers ``send`` so existing
  mocks keep working.

- **OpenRouter server-side tools** — `AgentConfiguration/openRouterServerTools`
  appends tools such as `openrouter:web_search`, `openrouter:web_fetch`, and
  `openrouter:datetime` to every completion request. OpenRouter executes them
  as the model invokes them (results return server-side, no client tool-call
  round-trip); well-known tools are predefined as
  ``OpenRouterServerTool/webSearch``, ``OpenRouterServerTool/webFetch``, and
  ``OpenRouterServerTool/datetime(timezone:)``, each with optional
  `parameters`.

- `MicrophoneRecorder` now fails fast with
  ``HarnessError/recordingFailed(_:)`` after 3 seconds of pure-zero input —
  a live microphone always delivers a nonzero noise floor, so prolonged
  silence means the input route is dead (for example a simulator without
  audio input) instead of waiting forever for an utterance that can never
  start.

### Changed

- `MicrophoneRecorder.stop()` now also ends an in-flight
  `recordUtterance(detection:)` early, returning the clip recorded so far and
  resuming the awaiting caller with it — a manual early stop instead of
  waiting for trailing-silence detection (previously it only ended manual
  `record()` sessions).

## [0.1.0] - 2026-09-21

Initial public release.

### Added

- **Agent with multi-stage tool calling** — `Agent` runs the model/tool loop
  against OpenRouter: tools are declared as Swift closures with JSON Schema
  parameters, the model's requests are executed, results flow back, and the
  loop repeats until a final answer (bounded by a configurable stage limit).
  Parallel calls, model-visible tool failures, conversation rollback on
  failed runs, live `AgentEvent` narration, and serialized concurrent runs.
- **Voice calling** — `VoiceSession` wraps an agent in a continuous
  *listen → transcribe → think → speak* call loop using ElevenLabs Scribe
  (speech-to-text) and ElevenLabs voices (text-to-speech). Includes an
  energy-based `UtteranceDetector` with hysteresis and duration limits, an
  actor-based `MicrophoneRecorder`, a barge-in `SpeechPlayer`, and
  `listenOnce`/`ask`/`say` building blocks for custom flows.
- **Usage statistics and cost estimation** — every completion is metered;
  `UsageRecord` per run and aggregated `UsageStatistics` per agent lifetime,
  with exact `Decimal` money, per-model breakdowns, and a strict separation
  of OpenRouter-reported costs from locally estimated ones
  (`CostEstimator` against the published pricing table). Account-level
  budget and rate limits via `fetchAPIKeyInfo()`.
- **Infrastructure** — `HTTPTransport` abstraction with a `URLSession`
  implementation, dynamically typed `JSONValue`, a unified `HarnessError`,
  and a keychain-backed `APIKeyStore` for credential storage.
- **Documentation** — full DocC reference with four guides (getting started,
  tool calling, voice calling, usage & costs).
- **Tests** — 63 offline tests covering the agent loop, wire encoding,
  cost math, multipart forms, voice building blocks, utterance detection,
  and key storage.

[0.1.0]: https://github.com/MCTzOCK/MobileHarness/releases/tag/0.1.0
