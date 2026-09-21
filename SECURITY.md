# Security Policy

## Supported versions

Security fixes target the latest published release. Pre-release versions receive fixes only until superseded.

## Reporting a vulnerability

**Do not open a public issue for anything security-relevant.**

Report privately via [GitHub security advisories](https://github.com/bensiebert/MobileHarness/security/advisories/new)
("Report a vulnerability"), which reaches the maintainer directly and supports
coordinated disclosure.

Please include:

- A description of the issue and its impact
- Steps or a proof of concept to reproduce it
- Affected versions/commit ranges, if known

You will receive an acknowledgement within a week. Please avoid public disclosure until a fix is released.

## Security-relevant scope

MobileHarness is a client library; it stores and transmits the credentials you give it.

- **Credential storage:** `KeychainAPIKeyStore` keeps API keys in the keychain, device-only. The harness never writes keys to `UserDefaults`, files, or logs. If you find a path where a key leaks into logs or errors, report it.
- **Transport:** all traffic goes to `openrouter.ai` and `api.elevenlabs.io` over HTTPS via `URLSession` default trust evaluation. There is no certificate pinning; apps that need pinning should layer it at the `URLSession` they inject via `HTTPTransport`.
- **Voice data:** recordings are held in memory, encoded to a temporary file, uploaded for transcription, and the temporary file is deleted. Nothing is persisted by the harness.
- **Supply chain:** the package has zero third-party dependencies.

## Handling of reports

Reports are triaged, fixed, and released as a patch version with credit to the reporter (unless anonymity is requested).
