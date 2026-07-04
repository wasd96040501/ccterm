import Combine
import Foundation

/// App-scope ⌘F focus bus. Replaces `TranscriptSearchBus` (@Observable).
/// The producer is the App menu's ⌘F item (routed through
/// `AppCoordinator.requestSearchFocus()`); the consumer is
/// `MainWindowController`, which owns the toolbar's search field and
/// hands it first-responder status on every request.
///
/// A `PassthroughSubject` is the right shape for this: one-shot
/// signals with no retained value (multiple ⌘Fs in a row must each fire
/// the sink, and there is nothing to "remember" between them).
@MainActor
final class SearchBusService {
    let focusRequests = PassthroughSubject<Void, Never>()

    init() {}

    func requestFocus() {
        focusRequests.send(())
    }

    nonisolated deinit {}
}
