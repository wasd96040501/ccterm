# AgentSDK

Swift package wrapping the `claude` CLI subprocess (`Session`, `SessionConfiguration`, the `Message2` JSONL model under `Sources/AgentSDK/Generated/`). The app reaches it only through `CLIClient` (`ccterm/Services/Session/CLIClient/`); tests inject `FakeCLIClient` there instead of spawning a CLI.

## Smoke executables (real `claude` CLI)

Anything that must run against a real CLI is an `executableTarget` here, **not an XCTest** — an XCTest in `cctermTests` boots the host app (`CCTermApp` startup, git probing) before the test body runs, so a smoke there takes minutes to fail for reasons unrelated to the smoke.

```bash
cd macos/AgentSDK
swift run <Name>          # e.g. DumpSmoke, InterruptSmoke, SideQuestionSmoke
```

- One target per `Sources/<Name>/main.swift`; the file's header comment states what it verifies and its env vars.
- Common env: `CLAUDE_BINARY_PATH` (override binary lookup), `SMOKE_MODEL` (default `claude-haiku-4-5`), `SMOKE_PROMPT`.
- Each run works in `/tmp/ccterm-<name>-<timestamp>/` (exported JSONL included) and leaves it for inspection.
- A new smoke: add the `executableTarget` to `Package.swift` and a header comment in its `main.swift` — no other registry to update.
