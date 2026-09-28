# AgentSDK

Swift package over the `claude` CLI: a live `Session` on the stream-json stdio protocol, the typed message model it emits, typed tool inputs/outputs, `Transcript` (a session file resolved the way `--resume` does) and one-shot `Prompt.run`. General-purpose — nothing here knows about ccterm.

## Layout

| Dir | Holds |
|---|---|
| `Protocol/` | What the CLI says: `Message` (one enum over every line type) and its payloads, `ContentBlock`, `StreamEvent`, `JSONValue`, `Usage`. |
| `Session/` | Talking to a live CLI: `Session` (events, handshake, control RPCs), `SessionConfiguration` and its launch flags, `UserInput`, `PermissionRequest` / `PermissionDecision` / `PermissionUpdate`, `InitializationResult`, `ContextUsage`, `MessageExporter`. |
| `Settings/` | `Settings` (a `settings.json` object), `SettingsKey<Value>` and its catalog (`SettingsKey+<Area>.swift`), `SettingsValue`, value types (`PermissionSettings`, …), `SettingsSnapshot` (`Session.settings()`). |
| `Tools/` | `Tools.<Name>` — typed input/output per built-in tool; `ToolUseBlock.input(as:)`, `UserMessage.toolOutcome(_:)`. |
| `Transcript/` | `Transcript(contentsOf:)` — the conversation chain from a session file (rewinds, forks, compactions, parallel calls). |
| `Prompt/` | `Prompt.run` — one-shot `claude -p` with a timeout. |
| `Process/` | Binary lookup, login-shell environment, custom launch commands. |

## Rules

- **Decoding never crashes or throws past the boundary.** Unknown line types, content blocks, tool names and enum values land in an `.unknown(JSONValue)` / raw-string case; a malformed optional field decodes as `nil`. Only a field without which the value is meaningless (a message's `type`) is required. New CLI fields appear as `JSONValue` until a consumer needs them typed.
- **Types are derived from real output, hand-maintained.** Before adding or changing a type, capture the wire shape with a smoke or `CorpusAudit` and add a synthetic fixture to the package tests. Field names follow Swift conventions (`toolUseID`), never the wire's.
- **Public surface stays small.** Public types expose what a consumer reads or builds; parsing helpers, process plumbing and wire encodings stay internal. A value a consumer only needs to *construct* for tests or previews gets a public `init`, not widened internals.
- **Settings keys are an open catalog.** A key is cataloged when it governs session behavior a host would set, its schema was read from the CLI source, and `SettingsSmoke` applies it. The CLI answers `success` to a value its schema rejects and then ignores the layer, so the smoke is what catches a catalog type drifting from the schema. Adding one:
  - a static member in `SettingsKey+<Area>.swift`, in an extension constrained to its value type, named after the `settings.json` key with Swift acronym casing (`promptCacheTtl` → `promptCacheTTL`);
  - its value type conforms to `SettingsValue`: a `String`-backed enum by declaration; a struct maps every field and carries unmodeled ones through, because an applied object replaces its whole value;
  - a doc comment saying what it controls and anything known about when it takes effect or whether the layer keeps it (`effortLevel: max`);
  - an entry in `SettingsSmoke`'s every-key apply and in `SettingsTests.testCatalogKeysMatchSettingsJSON`.
  A shape not worth modeling yet takes `JSONValue` as its value type (`hooks`).
- **Session semantics:** `start()` is the handshake; RPCs are `async throws` and send `control_cancel_request` when their task is cancelled; a process exit fails every pending call with `processExited(Termination)` and then yields `.exited`, which finishes `events`.

## Tests

`make test-sdk [FILTER=<Class>]` runs the package's XCTests (`Tests/AgentSDKTests`) — decoding, tools, transcript chain resolution, and `Session` driven over `Fixtures/fake_cli.py`, a scripted stand-in CLI (scenarios are picked by prompt text; see its header). CI runs it as the `test-sdk` job. Fixtures are synthetic; never commit real transcripts or exports.

## Smoke executables (real `claude` CLI)

Anything that must run against a real CLI is an `executableTarget` here, **not an XCTest** — an XCTest in `cctermTests` boots the host app (`CCTermApp` startup, git probing) before the test body runs, so a smoke there takes minutes to fail for reasons unrelated to the smoke.

```bash
cd macos/AgentSDK
swift run <Name>          # e.g. DumpSmoke, InterruptSmoke, SettingsSmoke
```

- One target per `Sources/<Name>/main.swift`; the file's header comment states what it verifies and its env vars. Each drives `Session` over stdio and prints PASS/FAIL per check, exiting non-zero on any failure.
- Common env: `CLAUDE_BINARY_PATH` (override binary lookup), `SMOKE_MODEL` (default `claude-haiku-4-5`), `SMOKE_PROMPT`.
- Each run works in `/tmp/ccterm-<name>-<timestamp>/` (exported JSONL included) and leaves it for inspection.
- `CorpusAudit` decodes local exports and transcripts and reports anything that fell back to `.unknown` — run it after a CLI upgrade.
- A new smoke: add the `executableTarget` to `Package.swift` and a header comment in its `main.swift` — no other registry to update.
