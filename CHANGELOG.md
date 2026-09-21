# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/bensiebert/MobileHarness/releases/tag/0.1.0
