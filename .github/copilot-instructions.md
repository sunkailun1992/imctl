# GitHub Copilot Instructions

This repository is a macOS controller that drives the real WeCom (企业微信) desktop client through Accessibility and sends messages on a real account. Before suggesting or changing code, read `AGENTS.md` and `docs/ai-coding/README.md`.

Follow these project rules:

- No synthetic keyboard/mouse input anywhere except the single Return key posted to the client pid in `Sources/WeComAdapter/Actions/KeystrokeInjector.swift`; `ForbiddenAPITests` fails the build otherwise.
- The permission surface is Accessibility only. Do not add screen recording, input monitoring or other TCC APIs.
- Do not widen the compiled allowlist in `WeComClient`; widening goes through the local `policy.json` and is a human decision.
- Every state-changing action goes through `ActionPolicy`; sends go through `CommandExecutor` (idempotency key, checkpoint before the irreversible step, `unknown` after a crash, never re-run).
- Events are the truth (`event_id` monotonic, replayable); responses are a convenience; QoS 1 means every method must be idempotent.
- Never commit broker addresses, MQTT credentials, WeCom corp ids/secrets, proxy tokens, real contact titles or message text, raw AX dumps, or machine-specific absolute paths.
- Fixture tests passing is not live acceptance; live results belong in `docs/gates/` with conditions and evidence.

Detailed standards live in `docs/ai-coding/`.
