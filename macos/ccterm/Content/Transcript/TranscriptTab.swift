import AgentSDK
import AppKit

/// What an editor tab of the transcript feature is: a New tab, a session's
/// transcript, or a document opened beside one. It is the tab's
/// `NSTabViewItem.identifier`, so editor history can make a closed tab again
/// and opening the same thing twice finds the tab already open.
///
/// A New tab becomes its session's tab at Send: the window then sets the
/// item's identifier to `.transcript(url)` (`transcriptTab(_:didStartSessionAt:)`),
/// and back to a fresh `.newSession` if the launch is stopped before it
/// starts. History never remakes a New tab — its draft is gone.
///
/// The feature builds its own tabs (`makeItem`); the window that hosts them
/// only places them, and names nothing of what is inside.
nonisolated enum TranscriptTab: Hashable, Sendable {
    /// A New tab, by an identity of its own.
    case newSession(UUID)
    case transcript(URL)
    case document(DocumentReference)

    /// Decodes an `NSTabViewItem.identifier`; `nil` for anything that isn't a
    /// `TranscriptTab`.
    init?(identifier: Any?) {
        guard let tab = identifier as? TranscriptTab else { return nil }
        self = tab
    }

    /// The transcript this tab is, or belongs to: its session is the reader's
    /// while the tab is the active one. `nil` for a New tab.
    var transcriptURL: URL? {
        switch self {
        case .newSession: nil
        case .transcript(let url): url
        case .document(let reference): reference.transcriptURL
        }
    }
}

extension TranscriptTab {
    /// Builds a session's tab or a document's; identifier = the TranscriptTab
    /// value itself. `title` is used for `.transcript` only; a `.document` tab
    /// titles itself once loaded (callers pass ""). A `.newSession` is built by
    /// `makeNewSessionItem`, which takes what a New tab starts with.
    @MainActor static func makeItem(
        _ tab: TranscriptTab, title: String,
        context: Context,
        delegate: TranscriptTabDelegate
    ) -> NSTabViewItem {
        switch tab {
        case .newSession:
            return makeNewSessionItem(folder: nil, text: "", context: context, delegate: delegate)
        case .transcript(let url):
            let controller = SessionTabViewController(.session(url), title: title, context: context)
            controller.tabDelegate = delegate
            let item = NSTabViewItem(viewController: controller)
            item.identifier = tab
            return item
        case .document(let reference):
            return makeDocumentItem(reference, document: nil, sessions: context.sessions, delegate: delegate)
        }
    }

    /// A New tab starting in `folder` (`nil`: none known), its field holding
    /// `text` — the words of the last New tab closed in the window.
    @MainActor static func makeNewSessionItem(
        folder: URL?, text: String, context: Context, delegate: TranscriptTabDelegate
    ) -> NSTabViewItem {
        let item = NSTabViewItem(
            viewController: makeNewSession(folder: folder, text: text, context: context, delegate: delegate))
        item.identifier = TranscriptTab.newSession(UUID())
        return item
    }

    /// A New tab's controller with no tab — what the editor area shows when it
    /// has no tabs at all (design 08 *No tabs, no bar*). At Send the window
    /// moves it into the first tab.
    @MainActor static func makeNewSession(
        folder: URL?, text: String, context: Context, delegate: TranscriptTabDelegate
    ) -> NSViewController {
        let controller = SessionTabViewController(
            .draft(folder: folder, text: text), title: String(localized: "New Session"), context: context)
        controller.tabDelegate = delegate
        return controller
    }

    /// Whether `viewController` is a New tab nobody has touched — ⌘T selects
    /// it rather than adding another.
    @MainActor static func isUntouchedDraft(_ viewController: NSViewController) -> Bool {
        (viewController as? SessionTabViewController)?.isUntouchedDraft ?? false
    }

    /// A New tab's words, for the next New tab when it closes; `nil` for any
    /// other tab.
    @MainActor static func draftText(of viewController: NSViewController) -> String? {
        (viewController as? SessionTabViewController)?.draftText
    }

    /// Internal, feature-only (not used by App/AppKit): a document tab from an already-resolved Document
    /// (synchronous, no blank frame). Identifier `.document(document.reference)`.
    @MainActor static func makeDocumentItem(
        _ document: Document, sessions: SessionStore,
        delegate: TranscriptTabDelegate
    ) -> NSTabViewItem {
        makeDocumentItem(document.reference, document: document, sessions: sessions, delegate: delegate)
    }

    /// Stops what the tab's controllers have in flight — a transcript's load,
    /// a document's, and a subagent's conversation inside one. The editor area
    /// calls it before the tab leaves the tree.
    @MainActor static func prepareForRemoval(_ viewController: NSViewController) {
        for controller in [viewController] + viewController.children {
            (controller as? SessionTabViewController)?.prepareForRemoval()
            (controller as? TranscriptViewController)?.prepareForRemoval()
            (controller as? DocumentViewController)?.prepareForRemoval()
        }
    }

    /// Gives the reader's focus to a document's tab, so the window's commands
    /// (⌘W) aim at what was just opened. Any other tab is left alone.
    @MainActor static func focus(_ item: NSTabViewItem) {
        (item.viewController as? DocumentViewController)?.takeFocus()
    }

    /// Brings `itemID` back into view in the transcript tab `item`, and flashes it.
    @MainActor static func reveal(_ itemID: String, in item: NSTabViewItem) {
        (item.viewController as? SessionTabViewController)?.reveal(itemID, select: true)
    }

    // MARK: - Building

    /// A subagent's conversation: a transcript on its own, following its file,
    /// reporting to the same delegate; nothing can be sent to it.
    @MainActor private static func makeConversation(
        _ url: URL, title: String, sessions: SessionStore, delegate: TranscriptTabDelegate?
    ) -> TranscriptViewController {
        let transcript = TranscriptViewController(fileURL: url, title: title, sessions: sessions)
        transcript.tabDelegate = delegate
        transcript.follow(sessions.states(at: url))
        return transcript
    }

    @MainActor private static func makeDocumentItem(
        _ reference: DocumentReference, document: Document?,
        sessions: SessionStore, delegate: TranscriptTabDelegate
    ) -> NSTabViewItem {
        weak var controller: DocumentViewController?
        let created = DocumentViewController(
            reference: reference, document: document,
            load: { documents($0, in: sessions) },
            makeConversation: { [weak delegate] url, title in
                makeConversation(url, title: title, sessions: sessions, delegate: delegate)
            },
            showInTranscript: { [weak delegate] reference in
                guard let delegate, let controller else { return }
                delegate.transcriptTab(
                    controller, didRequestReveal: reference.id, inTranscriptAt: reference.transcriptURL)
            },
            decide: { decision, callID in
                sessions.respond(toCall: callID, at: reference.transcriptURL) {
                    decision.permissionDecision(for: $0)
                }
            })
        controller = created
        let item = NSTabViewItem(viewController: created)
        item.identifier = TranscriptTab.document(reference)
        return item
    }

    /// The document `reference` names, as each state of its session has it —
    /// the page built off the main actor; `nil` when the session doesn't have
    /// it, or its transcript can't be read.
    @MainActor private static func documents(
        _ reference: DocumentReference, in sessions: SessionStore
    ) -> AsyncStream<Document?> {
        let states = sessions.states(at: reference.transcriptURL)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    for try await state in states {
                        continuation.yield(
                            TranscriptPage(state.transcript, partial: state.partial, requests: state.requests)
                                .document(reference))
                    }
                } catch {
                    continuation.yield(nil)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// What a tab of the feature asks of the window that hosts it.
@MainActor
protocol TranscriptTabDelegate: AnyObject {
    /// A New tab sent its first prompt: its session is at `url` from now. The
    /// delegate re-identifies the tab as `.transcript(url)` — or, for the New
    /// view the empty area shows, opens `source` as the first tab — before
    /// returning, and updates what the window shows of the active session
    /// (the tab stays the active one, so no activation is reported).
    func transcriptTab(_ source: NSViewController, didStartSessionAt url: URL)
    /// A launch stopped while starting: the tab is a New tab again.
    func transcriptTabDidReturnToDraft(_ source: NSViewController)
    /// The delegate first tries to select an open tab with identifier `tab`; only if none is open does it call
    /// `makeItem` (non-escaping) — so an already-open document builds nothing, exactly as today.
    func transcriptTab(
        _ source: NSViewController, didRequestOpen tab: TranscriptTab, pinned: Bool,
        makeItem: () -> NSTabViewItem)
    /// Show-in-Transcript: select the open transcript tab and reveal the item; no-op + log if not open.
    func transcriptTab(_ source: NSViewController, didRequestReveal itemID: String, inTranscriptAt url: URL)
}
