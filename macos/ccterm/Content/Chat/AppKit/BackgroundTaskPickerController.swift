import AppKit
import Observation

/// AppKit replacement for `BackgroundTaskButton.swift` (migration plan §4.2).
/// Footer-row trigger HIDDEN until `session.tasks` is non-empty; once shown it
/// stays until `tasks` empties (§4.2). Label = leading status dot (green if any
/// running, else tertiary) + "N running" / "N completed". Opens the task-list
/// popover; a row tap opens the detail SHEET at the WINDOW level (§4.2-5, R5).
@MainActor
final class BackgroundTaskPickerController: ChromePickerController {

    private let dot = NSView()
    private let dotLayer = CALayer()
    private let label = NSTextField(labelWithString: "")
    private var triggerObservationActive = false
    private weak var openListVC: BackgroundTaskListContentViewController?

    /// Owned detail-sheet presenter (window-level, §4.2-5, R5). Dismissed in
    /// `teardown` (called from InputBarController.prepareForRemoval).
    let detailPresenter = BackgroundTaskDetailPresenter()

    override init() {
        super.init()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dotLayer.cornerRadius = 3
        dot.layer?.addSublayer(dotLayer)
        label.font = ChromeButton.labelFont
        label.textColor = .labelColor
        button.contentStack.spacing = 6
        button.contentStack.addArrangedSubview(dot)
        button.contentStack.addArrangedSubview(label)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    nonisolated deinit {}

    override func teardown() {
        super.teardown()
        detailPresenter.stop()
    }

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
        let tasks = session.tasks
        button.isHidden = tasks.isEmpty
        guard !tasks.isEmpty else { return }

        let running = tasks.filter { $0.status == .running }.count
        let isRunning = running > 0
        let dotColor: NSColor = isRunning ? .systemGreen : .tertiaryLabelColor
        var resolved = dotColor.cgColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = dotColor.cgColor
        }
        dotLayer.frame = CGRect(x: 0, y: 0, width: 6, height: 6)
        dotLayer.backgroundColor = resolved

        if isRunning {
            label.stringValue = String(localized: "\(running) running")
        } else {
            label.stringValue = String(localized: "\(tasks.count) completed")
        }
        if running > 0 {
            button.setAccessibilityLabel(String(localized: "\(running) running, \(tasks.count) total"))
        } else {
            button.setAccessibilityLabel(String(localized: "\(tasks.count) background tasks"))
        }
        button.contentDidChange()
    }

    private func startTriggerObservation(for session: Session) {
        triggerObservationActive = true
        observeTrigger(session)
    }

    private func observeTrigger(_ session: Session) {
        withObservationTracking {
            _ = session.tasks
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

    // MARK: - Popover content

    override func makePopoverContentViewController() -> NSViewController {
        guard let session = boundSession else {
            return PopoverScrollContentViewController(width: BackgroundTaskListContentViewController.popoverWidth)
        }
        let vc = BackgroundTaskListContentViewController(
            session: session,
            onSelectTask: { [weak self] taskId in self?.openDetail(taskId: taskId) })
        openListVC = vc
        return vc
    }

    override func popoverWillBecomeShown() {
        openListVC?.startTicking()
    }

    override func popoverDidBecomeHidden() {
        openListVC?.stopTicking()
        openListVC = nil
    }

    // MARK: - Row tap → window-level detail sheet (§4.2-5, R5)

    private func openDetail(taskId: String) {
        guard let session = boundSession else { return }
        // Capture the main window ref BEFORE performClose (§4.2-5).
        let window = anchorWindow
        // Close the popover first.
        if isPopoverShown { toggle() }
        // beginSheet on the next runloop tick so the transient close + key-window
        // resignation settle (avoids the popover-behind-sheet hang).
        DispatchQueue.main.async { [weak self] in
            guard let self, let window else { return }
            self.detailPresenter.present(taskId: taskId, session: session, window: window)
        }
    }

    // MARK: - Test-observation points

    var triggerHiddenForTest: Bool { button.isHidden }
    var triggerLabelForTest: String { label.stringValue }
    /// Synchronous open used by tests to drive the row-select closure without
    /// the async hop's window dependency surprises.
    func openDetailForTest(taskId: String) {
        openDetail(taskId: taskId)
    }
}

/// AppKit replacement for `BackgroundTaskList.swift` popover body. Width 360,
/// maxHeight 480. Groups Running (receive order) then Completed (endedAt ??
/// startedAt desc). A 1s `.common`-mode timer re-labels elapsed counters while
/// the popover is open (§4.2-6, R17); started/stopped from the picker's
/// popover lifecycle.
@MainActor
final class BackgroundTaskListContentViewController: PopoverScrollContentViewController {

    static let popoverWidth: CGFloat = 360

    private let session: Session
    private let onSelectTask: (String) -> Void
    private var timer: Timer?
    private var observationActive = false
    private var now = Date()
    /// Per-row labels keyed by task id so the 1s tick re-labels in place.
    private var subtitleLabels: [String: NSTextField] = [:]

    init(session: Session, onSelectTask: @escaping (String) -> Void) {
        self.session = session
        self.onSelectTask = onSelectTask
        super.init(width: Self.popoverWidth, maxHeight: 480, outerPadding: 12, documentStackSpacing: 14)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    override func loadView() {
        super.loadView()
        reload()
    }

    // MARK: - Grouping (verbatim from BackgroundTaskList.group)

    struct TaskGroup: Equatable {
        let id: String
        let title: String
        let tasks: [BackgroundTask]
    }

    static func group(tasks: [BackgroundTask]) -> [TaskGroup] {
        let running = tasks.filter { $0.status == .running }
        let done = tasks.filter { $0.status != .running }
        var out: [TaskGroup] = []
        if !running.isEmpty {
            out.append(TaskGroup(id: "running", title: String(localized: "Running"), tasks: running))
        }
        if !done.isEmpty {
            let sorted = done.sorted { lhs, rhs in
                (lhs.endedAt ?? lhs.startedAt) > (rhs.endedAt ?? rhs.startedAt)
            }
            out.append(TaskGroup(id: "completed", title: String(localized: "Completed"), tasks: sorted))
        }
        return out
    }

    // MARK: - Timer (1s, .common; §4.2-6, R17)

    func startTicking() {
        observationActive = true
        observe()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopTicking() {
        observationActive = false
        timer?.invalidate()
        timer = nil
    }

    private func observe() {
        withObservationTracking {
            _ = session.tasks
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.observationActive else { return }
                self.reload()
                self.observe()
            }
        }
    }

    /// Re-label only — never writes @Observable (§4.2-6).
    private func tick() {
        now = Date()
        for task in session.tasks {
            guard let label = subtitleLabels[task.id] else { continue }
            let timing = BackgroundTaskFormat.elapsedDescription(task: task, now: now)
            label.stringValue = BackgroundTaskFormat.statusedSubtitle(task: task, timing: timing)
        }
    }

    private func reload() {
        now = Date()
        subtitleLabels.removeAll()
        // Each group is ONE composite arranged subview (header + rows-stack with
        // spacing 4); the document stack's spacing 14 separates the groups
        // (BackgroundTaskList.swift section spacing 14 / rows spacing 4).
        let groups = Self.group(tasks: session.tasks).map { makeGroupView($0) }
        populate(groups)
    }

    private func makeGroupView(_ group: TaskGroup) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6  // header → rows-stack gap (section spacing 6).
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Header (hpad 4).
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 6
        let title = NSTextField(labelWithString: group.title)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let count = NSTextField(labelWithString: "\(group.tasks.count)")
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .tertiaryLabelColor
        header.addArrangedSubview(title)
        header.addArrangedSubview(count)
        let headerWrapper = NSView()
        headerWrapper.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        headerWrapper.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: headerWrapper.leadingAnchor, constant: 4),
            header.trailingAnchor.constraint(lessThanOrEqualTo: headerWrapper.trailingAnchor),
            header.topAnchor.constraint(equalTo: headerWrapper.topAnchor),
            header.bottomAnchor.constraint(equalTo: headerWrapper.bottomAnchor),
        ])
        stack.addArrangedSubview(headerWrapper)
        headerWrapper.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Rows (spacing 4).
        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 4
        for task in group.tasks {
            let (row, subtitle) = makeTaskRow(task)
            subtitleLabels[task.id] = subtitle
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(rowsStack)
        rowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return stack
    }

    /// One task row (BackgroundTaskRow.swift). Returns the row + its subtitle
    /// label so the 1s tick can re-label.
    private func makeTaskRow(_ task: BackgroundTask) -> (NSView, NSTextField) {
        let titleField = NSTextField(labelWithString: Self.titleLine(task))
        titleField.font = .systemFont(ofSize: 13)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1

        let timing = BackgroundTaskFormat.elapsedDescription(task: task, now: now)
        let subtitleField = NSTextField(
            labelWithString: BackgroundTaskFormat.statusedSubtitle(task: task, timing: timing))
        subtitleField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.maximumNumberOfLines = 1

        let row = BackgroundTaskRowView(
            status: task.status, title: titleField, subtitle: subtitleField,
            onSelect: { [weak self] in self?.onSelectTask(task.id) })
        return (row, subtitleField)
    }

    static func titleLine(_ task: BackgroundTask) -> String {
        if let desc = task.description, !desc.isEmpty { return desc }
        if let cmd = task.command, !cmd.isEmpty {
            return cmd.split(separator: "\n").first.map(String.init) ?? cmd
        }
        return String(localized: "Background task")
    }
}

/// One clickable task row: status dot (8×8) + title/subtitle stack + trailing
/// chevron, hover background r8. padding h10/v8 (BackgroundTaskRow.swift).
final class BackgroundTaskRowView: PopoverRowBaseView {

    init(
        status: BackgroundTask.Status, title: NSTextField, subtitle: NSTextField,
        onSelect: @escaping () -> Void
    ) {
        super.init(onSelect: onSelect)

        let dot = NSView()
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.cornerRadius = 4
        let dotColor: NSColor
        switch status {
        case .running: dotColor = .systemGreen
        case .completed: dotColor = .tertiaryLabelColor
        case .failed: dotColor = .systemRed
        case .stopped: dotColor = .systemOrange
        }
        var resolved = dotColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = dotColor.cgColor }
        dot.layer?.backgroundColor = resolved

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(subtitle)

        let chevron = NSImageView(
            image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
                ?? NSImage())
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(textStack)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            textStack.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 8),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}
}
