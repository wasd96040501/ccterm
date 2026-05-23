# Context-usage popover — work in progress

Tracks the PR adding `get_context_usage` plumbing + the new ring popover.
This file is deleted in the final commit; it just lets the placeholder
commit be a real change so the PR can open.

Scope:

1. AgentSDK: `getContextUsage(timeout:completion:)` + `ContextUsage` typed response.
2. CLIClient protocol pass-through + Session façade caching.
3. ContextRingButton: click → async fetch → render categories bar + breakdown.
4. Fix percentage rounding (truncate → round).
5. Smoke target + unit tests.
