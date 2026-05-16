#if DEBUG

import Foundation

/// "Echo user, then complete turn" scenario, registered specifically for the
/// image-attach UI tests. Inherits all default behavior from
/// `MockCLIBaseScenario` — the existing default `onUserMessage` already
/// echoes and emits `result.success`, which is exactly what we want.
///
/// Image messages arrive at the mock as a `user` JSON whose `content` is an
/// array of `[text, image]` blocks; `MockCLIIncoming.parse` extracts the
/// text portion (caption, possibly empty). The base scenario's echo step
/// matches by `uuid`, so the queued→confirmed handoff works regardless of
/// content kind; we don't need to introspect image data on the mock side.
///
/// Kept separate from `HangingTurnScenario` because the stop-button test
/// needs a turn that never completes, while the image flow tests need the
/// turn to complete cleanly so the input bar returns to send-button state.
final class ImageEchoScenario: MockCLIBaseScenario {}

#endif
