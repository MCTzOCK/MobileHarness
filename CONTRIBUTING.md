# Contributing to MobileHarness

Thanks for your interest in improving MobileHarness! This document covers the practical details.

## Getting started

1. Fork and clone the repository.
2. Open the package: `open Package.swift` (Xcode) or work from the command line with `swift build`.
3. Run the test suite before changing anything:

   ```sh
   swift test
   ```

   Requirements: Xcode 26+ with the iOS 26 / macOS 26 SDKs. The suite is fully offline — all OpenRouter and ElevenLabs traffic runs through in-process mocks.

## Ground rules

- **Every change ships with tests.** Bug fixes need a failing test that the fix turns green; features need coverage of the observable behavior.
- **Keep the public API small and documented.** Every public symbol gets a DocC comment (summary line, parameters, returns, throws). If a feature can live behind an existing type instead of a new one, prefer that.
- **Concurrency is part of the contract.** The package compiles in Swift 6 language mode with strict concurrency. New types must be `Sendable` by construction; shared mutable state belongs in an actor.
- **Money is `Decimal`.** Never route USD amounts through `Double` arithmetic.
- **Wire types must match the APIs.** If you touch request/response decoding, verify the shape against the [OpenRouter OpenAPI spec](https://openrouter.ai/openapi.json) or the [ElevenLabs API reference](https://elevenlabs.io/docs/api-reference) and cite the endpoint in your PR description.

## Before you open a pull request

```sh
swift build                                # compiles for macOS host
swift test                                 # full offline suite
xcodebuild -scheme MobileHarness \
  -destination 'generic/platform=iOS' build # iOS platform build
```

Commit messages: imperative subject line (`Add …`, `Fix …`), a body explaining why when the change isn't self-evident. Keep commits focused; one logical change each.

## Reporting bugs

Open an issue with: what you did, what you expected, what happened, and the smallest code sample that reproduces it. Include the `HarnessError` description if one surfaced — it carries the HTTP status and service message.

## Security issues

Do not open public issues for security problems — see [SECURITY.md](SECURITY.md).
