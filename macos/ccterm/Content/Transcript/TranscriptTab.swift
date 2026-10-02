import AgentSDK
import AppKit

/// What an editor tab of the transcript feature is: a session's transcript,
/// or a document opened beside one. It is the tab's `NSTabViewItem.identifier`,
/// so editor history can make a closed tab again and opening the same thing
/// twice finds the tab already open.
///
/// The feature builds its own tabs (`makeItem`); the window that hosts them
/// only places them, and names nothing of what is inside.
nonisolated enum TranscriptTab: Hashable, Sendable {
    case transcript(URL)
    case document(DocumentReference)

    /// Decodes an `NSTabViewItem.identifier`; `nil` for anything that isn't a
    /// `TranscriptTab`.
    init?(identifier: Any?) {
        guard let tab = identifier as? TranscriptTab else { return nil }
        self = tab
    }

    /// The transcript this tab is, or belongs to: its session is the reader's
    /// while the tab is the active one.
    var transcriptURL: URL {
        switch self {
        case .transcript(let url): url
        case .document(let reference): reference.transcriptURL
        }
    }
}

extension TranscriptTab {
    /// Builds the tab item; identifier = the TranscriptTab value itself.
    /// `title` is used for `.transcript` only; a `.document` tab titles itself once loaded (callers pass "").
    /// Every tab reads and talks to its session through `sessions`.
    @MainActor static func makeItem(
        _ tab: TranscriptTab, title: String,
        sessions: SessionStore,
        delegate: TranscriptTabDelegate
    ) -> NSTabViewItem {
        switch tab {
        case .transcript(let url):
            let item = NSTabViewItem(
                viewController: makeTranscript(
                    url, title: title, sessions: sessions, acceptsInput: true, delegate: delegate))
            item.identifier = tab
            return item
        case .document(let reference):
            return makeDocumentItem(reference, document: nil, sessions: sessions, delegate: delegate)
        }
    }

    /// Internal, feature-only (not used by App/AppKit): a document tab from an already-resolved Document
    /// (synchronous, no blank frame). Identifier `.document(document.reference)`.
    @MainActor static func makeItem(
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
        (item.viewController as? TranscriptViewController)?.reveal(itemID, select: true)
    }

    // MARK: - Building

    /// Every transcript controller the feature builds — a tab's, a subagent's
    /// conversation — reports to the same delegate; only a session's own tab
    /// takes input.
    @MainActor private static func makeTranscript(
        _ url: URL, title: String, sessions: SessionStore, acceptsInput: Bool, delegate: TranscriptTabDelegate?
    ) -> TranscriptViewController {
        let transcript = TranscriptViewController(
            fileURL: url, title: title, sessions: sessions, acceptsInput: acceptsInput)
        transcript.delegate = delegate
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
                makeTranscript(url, title: title, sessions: sessions, acceptsInput: false, delegate: delegate)
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
    /// The delegate first tries to select an open tab with identifier `tab`; only if none is open does it call
    /// `makeItem` (non-escaping) — so an already-open document builds nothing, exactly as today.
    func transcriptTab(
        _ source: NSViewController, didRequestOpen tab: TranscriptTab, pinned: Bool,
        makeItem: () -> NSTabViewItem)
    /// Show-in-Transcript: select the open transcript tab and reveal the item; no-op + log if not open.
    func transcriptTab(_ source: NSViewController, didRequestReveal itemID: String, inTranscriptAt url: URL)
}
