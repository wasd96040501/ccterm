# AgentSDK

Swift package over the `claude` CLI: a live `Session` on the stream-json stdio protocol, the typed message model it emits, typed tool inputs/outputs, `Transcript` (a session file read as the conversation a live `Session` would have emitted) and one-shot `Prompt.run`. General-purpose — nothing here knows about ccterm.

## Layout

| Dir | Holds |
|---|---|
| `Process/` | Starting the CLI: `CLILaunch` resolves the executable (binary lookup, or a custom launch command through the login shell) and the environment once for `Session`, `Prompt`, `Auth` and `CLIVersion`, which only build arguments; `CLIConfiguration` (the launch knobs of a one-off run), `CLIVersion.probe` (`--version`), `LaunchLine` (a shell launch line read into assignments, command and arguments); `CLIProcess` (the subprocess and its pipes), `CLIOutput` (a one-shot run to its exit), `Termination`, `AgentSDKError`; internal `BinaryLocator` (where `claude` is), `CustomCommand` (the login-shell invocation) and `ShellEnvironment` (login env and alias probe). |
| `Protocol/` | What the CLI says and takes: `Message` (one enum over every line type) and its payloads, `ContentBlock`, `StreamEvent`, `JSONValue`, `Usage`; the values it takes as flags and settings (`PermissionMode`, `Effort`, `PermissionRule`, `PermissionBehavior`) and `SettingsValue`, a value's `settings.json` form; `ToolDefinition` / `ToolOutcome`, how a tool call reads typed (`ToolUseBlock.input(as:)`, `UserMessage.toolOutcome(_:)`); the decoding plumbing every reader shares (`AnyCodingKey`, lenient containers, `concurrentMap`). |
| `Protocol/UserText/` | What a user message is — typed text, a local command, a task report, another party's message — read from the markup the CLI writes into its text: `UserMessage.kind`, `TaskReport`, `TaggedElement`. |
| `Tools/` | `Tools.<Name>` — the built-in tools' definitions, typed input/output per tool. |
| `Settings/` | `Settings` (a `settings.json` object), `SettingsKey<Value>` and its catalog (`SettingsKey+<Area>.swift`), value types (`PermissionSettings`, …), `SettingsSnapshot` (`Session.settings()`). |
| `Transcript/` | `Transcript(contentsOf:)` — a session file read as the messages a live `Session` would have emitted, first prompt to last reply; `Transcript.append(_:)` — the same conversation kept live, message by message; `Transcript.metadata(contentsOf:)` — its `SessionMetadata` (titles, cwd) from the file's head and tail only. |
| `SessionDirectory/` | `SessionDirectory` — the session, subagent and workflow-run files on disk (`SessionFile`, `SubagentFile`, `WorkflowRun`), and which sessions change (FSEvents, mapped to the session a file belongs to). |
| `Session/` | Talking to a live CLI: `Session` (events, handshake, typed control RPCs), `SessionConfiguration` and its launch flags, `UserInput`, `PermissionRequest` / `PermissionDecision` / `PermissionUpdate`, `InitializationResult`, `ContextUsage`, `RewindResult`, `MessageExporter`. |
| `Prompt/` | `Prompt.run` — one-shot `claude -p` with a timeout. |
| `Auth/` | `Auth` — the CLI's own login (`claude auth status / login / logout`), `AuthStatus`; configured by `CLIConfiguration`. |

Directories depend downward only, so the graph stays acyclic: `Process/` and `Protocol/` depend on nothing in the package; `Protocol/UserText/`, `Tools/`, `Settings/`, `Transcript/` and `SessionDirectory/` on `Protocol/`; `Session/` and `Prompt/` on `Process/`, `Protocol/` and `Settings/`; `Auth/` on `Process/`. No source file sits at the package root. A type two directories need lives in the lower one, with its conformances.

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
- **Launch environment precedence** (one rule for every launch): the login shell's rc exports < `CLIConfiguration.env` < the custom command's own assignments (its prefix, or its first word's alias body). A custom command's shell sources rc after the process env is set, so `CustomCommand.shellInvocation` re-exports `env` inside its script. `SessionDirectory(configuration:)` applies the same rule (one `-li` spawn for env and alias lookup) to find the projects directory; a wrapper script that sets `CLAUDE_CONFIG_DIR` internally is invisible to it. `SessionConfiguration(workingDirectory:launch:)` adopts a `CLIConfiguration`, so a session launches as a one-off run does.
- **Session semantics:** `start()` is the handshake; RPCs are `async throws` and send `control_cancel_request` when their task is cancelled; a process exit fails every pending call with `processExited(Termination)` and then yields `.exited`, which finishes `events`.

## Tests

`make test-sdk [FILTER=<Class>]` runs the package's XCTests (`Tests/AgentSDKTests`) — decoding, tools, transcript chain resolution, and `Session` driven over `Fixtures/fake_cli.py`, a scripted stand-in CLI (scenarios are picked by prompt text; see its header). CI runs it as the `test-sdk` job. Fixtures are synthetic; never commit real transcripts or exports.

## Smoke executables (real `claude` CLI)

Anything that must run against a real CLI is an `executableTarget` here, **not an XCTest** — an XCTest in `cctermTests` boots the host app (`AppDelegate` startup, git probing) before the test body runs, so a smoke there takes minutes to fail for reasons unrelated to the smoke.

```bash
cd macos/AgentSDK
swift run <Name>          # e.g. DumpSmoke, InterruptSmoke, SettingsSmoke
```

- One target per `Sources/<Name>/main.swift`; the file's header comment states what it verifies and its env vars. Each drives `Session` over stdio and prints PASS/FAIL per check, exiting non-zero on any failure.
- Common env: `CLAUDE_BINARY_PATH` (override binary lookup), `SMOKE_MODEL` (default `claude-haiku-4-5`), `SMOKE_PROMPT`.
- Each run works in `/tmp/ccterm-<name>-<timestamp>/` (exported JSONL included) and leaves it for inspection.
- `CorpusAudit` decodes local exports and transcripts and reports anything that fell back to `.unknown` — run it after a CLI upgrade.
- A new smoke: add the `executableTarget` to `Package.swift` and a header comment in its `main.swift` — no other registry to update.
