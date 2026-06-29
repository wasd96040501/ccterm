import AppKit
import Observation

/// AppKit replacement for `TodoButton.swift` (migration plan §4.2). Footer-row
/// trigger HIDDEN until `session.todos` is non-empty (§4.2 — `isHidden` toggle,
/// height-invariant). Label = leading `TodoStatusGlyphView` (muted) +
/// "completed of total". Opens the todo-list popover.
@MainActor
final class TodoPickerController: ChromePickerController {

    private let glyph = TodoStatusGlyphView(status: .pending, muted: true)
    private let label = NSTextField(labelWithString: "")
    private var triggerObservationActive = false
    private weak var openContentVC: TodoListContentViewController?

    override init() {
        super.init()
        glyph.translatesAutoresizingMaskIntoConstraints = false
        label.font = ChromeButton.labelFont
        label.textColor = .labelColor
        button.contentStack.spacing = 6
        button.contentStack.addArrangedSubview(glyph)
        button.contentStack.addArrangedSubview(label)
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 12),
            glyph.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    nonisolated deinit {}

    override func boundSessionChanged() {
        guard let session = boundSession else { return }
        refreshTrigger()
        startTriggerObservation(for: session)
    }

    override func cancelTriggerObservation() {
        triggerObservationActive = false
    }

    private func refreshTrigger() {
        guard let session = boundSession else { return }
        let todos = session.todos
        // HIDDEN until non-empty (stays once shown until todos empties).
        button.isHidden = todos.isEmpty
        guard !todos.isEmpty else { return }

        // Most-live glyph: inProgress > pending > completed (TodoButton.swift).
        let glyphStatus: TodoEntry.Status
        if todos.contains(where: { $0.status == .inProgress }) {
            glyphStatus = .inProgress
        } else if todos.contains(where: { $0.status == .pending }) {
            glyphStatus = .pending
        } else {
            glyphStatus = .completed
        }
        glyph.setState(glyphStatus, muted: true)

        let completed = todos.filter { $0.status == .completed }.count
        label.stringValue = String(localized: "\(completed) of \(todos.count)")
        button.setAccessibilityLabel(
            String(localized: "\(completed) of \(todos.count) todos completed"))
        button.contentDidChange()
    }

    private func startTriggerObservation(for session: Session) {
        triggerObservationActive = true
        observeTrigger(session)
    }

    private func observeTrigger(_ session: Session) {
        withObservationTracking {
            _ = session.todos
        } onChange: { [weak self, weak session] in
            DispatchQueue.main.async {
                guard let self, let session,
                    self.triggerObservationActive, self.boundSession === session
                else { return }
                self.refreshTrigger()
                self.observeTrigger(session)
            }
        }
    }

    override func makePopoverContentViewController() -> NSViewController {
        guard let session = boundSession else {
            return PopoverScrollContentViewController(width: TodoListContentViewController.popoverWidth)
        }
        let vc = TodoListContentViewController(session: session)
        openContentVC = vc
        return vc
    }

    override func popoverWillBecomeShown() {
        // The todo rotation re-keys on window attach inside TodoStatusGlyphView;
        // the content VC arms its own per-open observation.
        openContentVC?.startObserving()
    }

    override func popoverDidBecomeHidden() {
        openContentVC?.stopObserving()
        openContentVC = nil
    }

    // MARK: - Test-observation points

    var triggerHiddenForTest: Bool { button.isHidden }
    var triggerLabelForTest: String { label.stringValue }
}

/// AppKit replacement for `TodoList.swift` popover body. Memo-style rows in
/// creation order; completed rows dimmed + struck through. Width 340, maxHeight
/// 480. Live glyph (muted: false) — the popover gets the spinner. A per-open
/// re-armed observation reloads on `session.todos` change.
@MainActor
final class TodoListContentViewController: PopoverScrollContentViewController {

    static let popoverWidth: CGFloat = 340

    private let session: Session
    private var observationActive = false

    init(session: Session) {
        self.session = session
        // padding horizontal/vertical 14, spacing 2 (TodoList.swift:26-27,21).
        super.init(
            width: Self.popoverWidth, maxHeight: 480, outerPadding: 14, documentStackSpacing: 2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    override func loadView() {
        super.loadView()
        reload()
    }

    func startObserving() {
        observationActive = true
        observe()
    }

    func stopObserving() {
        observationActive = false
    }

    private func observe() {
        withObservationTracking {
            _ = session.todos
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.observationActive else { return }
                self.reload()
                self.observe()
            }
        }
    }

    private func reload() {
        populate(session.todos.map { TodoRowView(todo: $0) })
    }
}

/// One memo line: leading live status glyph (14×14, nudged down 4pt to center
/// on cap-height) + display text + optional description (TodoList.swift:40-107).
final class TodoRowView: NSView {

    init(todo: TodoEntry) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let glyph = TodoStatusGlyphView(status: todo.status, muted: false)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)

        let isCompleted = todo.status == .completed
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let displayText: String
        if todo.status == .inProgress, let active = todo.activeForm, !active.isEmpty {
            displayText = active
        } else {
            displayText = todo.subject
        }
        let titleField = NSTextField(wrappingLabelWithString: displayText)
        titleField.font = .systemFont(ofSize: 13)
        titleField.textColor = isCompleted ? .secondaryLabelColor : .labelColor
        if isCompleted {
            let attr = NSMutableAttributedString(string: displayText)
            attr.addAttributes(
                [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.secondaryLabelColor,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 13),
                ],
                range: NSRange(location: 0, length: attr.length))
            titleField.attributedStringValue = attr
        }
        textStack.addArrangedSubview(titleField)

        if let detail = todo.description, !detail.isEmpty {
            let detailField = NSTextField(wrappingLabelWithString: detail)
            detailField.font = .systemFont(ofSize: 11)
            detailField.textColor =
                isCompleted ? NSColor.secondaryLabelColor.withAlphaComponent(0.6) : .secondaryLabelColor
            detailField.maximumNumberOfLines = 2
            textStack.addArrangedSubview(detailField)
        }

        addSubview(textStack)

        // padding h4/v4; glyph nudged down 4pt to center on the first line's
        // cap-height (TodoRow.swift:52 alignmentGuide).
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: 4 + 4),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            glyph.heightAnchor.constraint(equalToConstant: 14),

            textStack.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}
}
