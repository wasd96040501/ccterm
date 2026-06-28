import AppKit
import Observation

/// Owned, window-level presenter for the background-task detail sheet (migration
/// plan §4.2-5, §4.7-1, R5). Mirrors `Transcript2SheetPresenter` /
/// `ImagePreviewPresenter`: idempotent + window-guarded, so a tapped detail
/// sheet can NEVER outlive the bar's teardown and wedge the window — dismissed
/// from `BackgroundTaskPickerController.teardown` (← InputBarController
/// prepareForRemoval). A free-hand `window.beginSheet` from the row-tap closure
/// is forbidden (R5).
@MainActor
final class BackgroundTaskDetailPresenter {

    private weak var presentedWindow: NSWindow?
    private var sheetWindow: NSWindow?
    private(set) var contentVC: BackgroundTaskDetailSheetViewController?

    nonisolated deinit {}

    /// Whether a sheet is currently presented. Read by tests.
    var isPresenting: Bool { sheetWindow != nil }

    /// Present the detail sheet for `taskId` over `window`. Idempotent: a second
    /// call while a sheet is up is a no-op (the popover-tap can't double-fire,
    /// but guard anyway, R5).
    func present(taskId: String, session: Session, window: NSWindow) {
        guard sheetWindow == nil else { return }
        let vc = BackgroundTaskDetailSheetViewController(
            taskId: taskId, session: session,
            onDismiss: { [weak self] in self?.stop() })
        vc.loadViewIfNeeded()
        let sheet = NSWindow(contentViewController: vc)
        sheet.styleMask = [.titled, .closable, .resizable]
        // Done/close keyEquivalent resolves to the VC's close action.
        presentedWindow = window
        sheetWindow = sheet
        contentVC = vc
        window.beginSheet(sheet) { [weak self] _ in
            // The sheet ended (close button / programmatic) — release.
            self?.releaseSheet()
        }
    }

    /// Dismiss + release. Idempotent + window-guarded.
    func stop() {
        guard let sheet = sheetWindow, let window = presentedWindow else {
            releaseSheet()
            return
        }
        window.endSheet(sheet)
        // endSheet's completion handler calls releaseSheet.
    }

    private func releaseSheet() {
        contentVC?.prepareForRemoval()
        sheetWindow = nil
        contentVC = nil
        presentedWindow = nil
    }
}

/// AppKit replacement for `BackgroundTaskDetailSheet.swift` (migration plan
/// §4.2-5). Presents one task's full state at the window level. Re-reads the
/// live `BackgroundTask` from `session.tasks` each 1s sample (status flips while
/// open). Owns a `BackgroundTaskOutputStream` keyed on the task's `outputFile`;
/// `stop()` on `viewWillDisappear` / `prepareForRemoval` for deterministic
/// file-tail teardown (§4.2-5).
@MainActor
final class BackgroundTaskDetailSheetViewController: NSViewController {

    static let sheetWidth: CGFloat = 640
    static let idealHeight: CGFloat = 560
    static let minHeight: CGFloat = 360
    static let maxHeight: CGFloat = 720

    private let taskId: String
    private let session: Session
    private let onDismiss: () -> Void
    private let onStop: (String) -> Void

    private var stream: BackgroundTaskOutputStream?
    private var timer: Timer?
    private var now = Date()

    private let titleLabel = NSTextField(labelWithString: "")
    private let statusPillLabel = NSTextField(labelWithString: "")
    private let kindDotView = NSView()
    private let kindLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let livePill = NSTextField(labelWithString: String(localized: "Live"))
    private let outputFileLabel = NSTextField(labelWithString: "")
    private let outputTextView = NSTextView()
    private let outputScroll = NSScrollView()
    /// Result/summary section (rendered only when terminal + summary present).
    private let summarySectionStack = NSStackView()
    private let summaryBodyLabel = NSTextField(labelWithString: "")
    /// Footer timestamp lines (Started always; Ended when terminal).
    private let startedLabel = NSTextField(labelWithString: "")
    private let endedLabel = NSTextField(labelWithString: "")
    private var streamObservationActive = false

    init(taskId: String, session: Session, onDismiss: @escaping () -> Void) {
        self.taskId = taskId
        self.session = session
        self.onDismiss = onDismiss
        self.onStop = { [session] id in session.stopBackgroundTask(taskId: id) }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    nonisolated deinit {}

    /// The live task re-read each sample (§4.2-5). Nil if it disappeared.
    private var liveTask: BackgroundTask? {
        session.tasks.first(where: { $0.id == taskId })
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(titleLabel)

        statusPillLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor
        kindLabel.font = .systemFont(ofSize: 12)
        kindLabel.textColor = .secondaryLabelColor
        // 3pt quaternary separator dot between status and type (metaDot).
        kindDotView.wantsLayer = true
        kindDotView.translatesAutoresizingMaskIntoConstraints = false
        kindDotView.layer?.cornerRadius = 1.5
        kindDotView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        NSLayoutConstraint.activate([
            kindDotView.widthAnchor.constraint(equalToConstant: 3),
            kindDotView.heightAnchor.constraint(equalToConstant: 3),
        ])
        let metaRow = NSStackView()
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 10
        metaRow.addArrangedSubview(statusPillLabel)
        metaRow.addArrangedSubview(kindDotView)
        metaRow.addArrangedSubview(kindLabel)
        metaRow.addArrangedSubview(elapsedLabel)
        stack.addArrangedSubview(metaRow)

        // Command header + value.
        let commandHeader = makeSectionHeader(String(localized: "Command"))
        stack.addArrangedSubview(commandHeader)
        let commandField = NSTextField(labelWithString: liveTask?.command ?? "—")
        commandField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandField.textColor = .labelColor
        commandField.isSelectable = true
        commandField.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(commandField)

        // Output header row: "OUTPUT" + Live pill (running + stream) + spacer +
        // output-file basename (with the full path as a tooltip).
        let outputHeaderRow = NSStackView()
        outputHeaderRow.orientation = .horizontal
        outputHeaderRow.alignment = .centerY
        outputHeaderRow.spacing = 8
        outputHeaderRow.addArrangedSubview(makeSectionHeader(String(localized: "Output")))
        livePill.font = .systemFont(ofSize: 10, weight: .semibold)
        livePill.textColor = .systemGreen
        livePill.isHidden = true
        outputHeaderRow.addArrangedSubview(livePill)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        outputHeaderRow.addArrangedSubview(headerSpacer)
        outputFileLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        outputFileLabel.textColor = .tertiaryLabelColor
        outputFileLabel.lineBreakMode = .byTruncatingMiddle
        outputFileLabel.maximumNumberOfLines = 1
        outputFileLabel.isHidden = true
        outputHeaderRow.addArrangedSubview(outputFileLabel)
        stack.addArrangedSubview(outputHeaderRow)
        outputHeaderRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        outputTextView.isEditable = false
        outputTextView.isSelectable = true
        outputTextView.drawsBackground = false
        outputTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        outputTextView.textColor = .labelColor
        outputScroll.documentView = outputTextView
        outputScroll.hasVerticalScroller = true
        outputScroll.drawsBackground = false
        outputScroll.borderType = .lineBorder
        outputScroll.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(outputScroll)
        NSLayoutConstraint.activate([
            outputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            outputScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 280),
            outputScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        // Result/summary section (terminal + summary present). Built once,
        // visibility toggled in refreshMeta.
        summarySectionStack.orientation = .vertical
        summarySectionStack.alignment = .leading
        summarySectionStack.spacing = 8
        summarySectionStack.addArrangedSubview(makeSectionHeader(String(localized: "Result")))
        summaryBodyLabel.font = .systemFont(ofSize: 12)
        summaryBodyLabel.textColor = .labelColor
        summaryBodyLabel.lineBreakMode = .byWordWrapping
        summaryBodyLabel.maximumNumberOfLines = 0
        summaryBodyLabel.preferredMaxLayoutWidth = Self.sheetWidth - 48
        summarySectionStack.addArrangedSubview(summaryBodyLabel)
        summarySectionStack.isHidden = true
        stack.addArrangedSubview(summarySectionStack)
        summarySectionStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Footer: Started/Ended timestamps + Stop (when running) + Done.
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        let timestampStack = NSStackView()
        timestampStack.orientation = .vertical
        timestampStack.alignment = .leading
        timestampStack.spacing = 2
        startedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        startedLabel.textColor = .secondaryLabelColor
        endedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        endedLabel.textColor = .secondaryLabelColor
        endedLabel.isHidden = true
        timestampStack.addArrangedSubview(startedLabel)
        timestampStack.addArrangedSubview(endedLabel)
        footer.addArrangedSubview(timestampStack)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)
        if liveTask?.status == .running {
            let stopButton = NSButton(
                title: String(localized: "Stop"), target: self, action: #selector(stopTapped))
            stopButton.bezelStyle = .rounded
            stopButton.controlSize = .small
            stopButton.contentTintColor = .systemRed
            footer.addArrangedSubview(stopButton)
        }
        let doneButton = NSButton(
            title: String(localized: "Done"), target: self, action: #selector(doneTapped))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        footer.addArrangedSubview(doneButton)
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            root.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minHeight),
        ])
        view = root
        preferredContentSize = NSSize(width: Self.sheetWidth, height: Self.idealHeight)
        refreshMeta()
    }

    private func makeSectionHeader(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        rebindStream()
        // Re-run meta now the stream is bound so the Live pill / output-file
        // label / summary reflect the live state (loadView ran before bind).
        refreshMeta()
        startTicking()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Deterministic file-tail teardown (§4.2-5).
        stream?.stop()
        stopTicking()
    }

    /// Teardown hook from the presenter (idempotent file-tail stop).
    func prepareForRemoval() {
        stream?.stop()
        stream = nil
        stopTicking()
    }

    // MARK: - Stream

    private func rebindStream() {
        guard let path = liveTask?.outputFile else {
            stream?.stop()
            stream = nil
            return
        }
        if stream?.path != path {
            stream?.stop()
            let next = BackgroundTaskOutputStream(path: path)
            stream = next
            next.start()
        } else {
            stream?.start()
        }
        armStreamObservation()
        refreshOutput()
    }

    private func armStreamObservation() {
        guard let stream else { return }
        streamObservationActive = true
        observeStream(stream)
    }

    private func observeStream(_ stream: BackgroundTaskOutputStream) {
        withObservationTracking {
            _ = stream.text
        } onChange: { [weak self, weak stream] in
            DispatchQueue.main.async {
                guard let self, let stream, self.streamObservationActive, self.stream === stream
                else { return }
                self.refreshOutput()
                self.observeStream(stream)
            }
        }
    }

    private func refreshOutput() {
        // Mirror SwiftUI BackgroundTaskOutputView.displayed: real text wins, else
        // a placeholder keyed on the stream's missing/starting state; and the
        // pre-stream "No output file available" / "Loading output…" cases.
        let placeholder: String
        if let stream {
            if !stream.text.isEmpty {
                outputTextView.string = stream.text
                outputTextView.scrollToEndOfDocument(nil)
                return
            }
            if stream.fileMissing {
                placeholder = String(localized: "Waiting for output…")
            } else if stream.isStarting {
                placeholder = String(localized: "Loading…")
            } else {
                placeholder = String(localized: "(no output yet)")
            }
        } else if liveTask?.outputFile == nil {
            placeholder = String(localized: "No output file available")
        } else {
            placeholder = String(localized: "Loading output…")
        }
        outputTextView.string = placeholder
    }

    // MARK: - 1s tick (live re-read)

    private func startTicking() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTicking() {
        streamObservationActive = false
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        now = Date()
        refreshMeta()
    }

    private func refreshMeta() {
        guard let task = liveTask else { return }
        // Title: description ?? first-line(command) ?? "Background task".
        if let desc = task.description, !desc.isEmpty {
            titleLabel.stringValue = desc
        } else if let cmd = task.command, !cmd.isEmpty {
            titleLabel.stringValue = cmd.split(separator: "\n").first.map(String.init) ?? cmd
        } else {
            titleLabel.stringValue = String(localized: "Background task")
        }
        statusPillLabel.stringValue = BackgroundTaskFormat.statusLabel(task.status)
        statusPillLabel.textColor = statusColor(task.status)
        elapsedLabel.stringValue = BackgroundTaskFormat.elapsedDescription(task: task, now: now)

        // displayKind chip ("bash" / underscored type) — hidden when no type.
        if let kind = Self.displayKind(task), !kind.isEmpty {
            kindLabel.stringValue = kind
            kindLabel.isHidden = false
            kindDotView.isHidden = false
        } else {
            kindLabel.isHidden = true
            kindDotView.isHidden = true
        }

        // Live pill: running AND a stream is bound (matches SwiftUI guard).
        livePill.isHidden = !(task.status == .running && stream != nil)

        // Output-file basename + full-path tooltip.
        if let path = task.outputFile {
            outputFileLabel.stringValue = (path as NSString).lastPathComponent
            outputFileLabel.toolTip = path
            outputFileLabel.isHidden = false
        } else {
            outputFileLabel.isHidden = true
        }

        // Result/summary section: terminal + summary present.
        if let summary = task.summary, task.isTerminal {
            summaryBodyLabel.stringValue = summary
            summarySectionStack.isHidden = false
        } else {
            summarySectionStack.isHidden = true
        }

        // Footer timestamps: Started always; Ended when terminal.
        startedLabel.stringValue =
            String(localized: "Started") + " " + Self.timeFormatter.string(from: task.startedAt)
        if let ended = task.endedAt {
            endedLabel.stringValue =
                String(localized: "Ended") + " " + Self.timeFormatter.string(from: ended)
            endedLabel.isHidden = false
        } else {
            endedLabel.isHidden = true
        }
    }

    /// `displayKind` parity with `BackgroundTaskDetailSheet.displayKind`:
    /// `local_bash` → "bash"; nil → nil; else underscores→spaces.
    private static func displayKind(_ task: BackgroundTask) -> String? {
        switch task.taskType?.lowercased() {
        case "local_bash": return String(localized: "bash")
        case nil: return nil
        case let other?: return other.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Hour-minute-second time formatter (matches SwiftUI
    /// `.dateTime.hour().minute().second()`).
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    private func statusColor(_ status: BackgroundTask.Status) -> NSColor {
        switch status {
        case .running: return .systemGreen
        case .completed: return .secondaryLabelColor
        case .failed: return .systemRed
        case .stopped: return .systemOrange
        }
    }

    @objc private func stopTapped() {
        onStop(taskId)
    }

    @objc private func doneTapped() {
        onDismiss()
    }

    /// Esc-to-dismiss (matches the SwiftUI `.cancelAction`).
    override func cancelOperation(_ sender: Any?) {
        onDismiss()
    }

    // MARK: - Test-observation points

    var titleForTest: String { titleLabel.stringValue }
    var statusForTest: String { statusPillLabel.stringValue }
    /// Whether the file-tail stream is alive (for the teardown test).
    var streamStartedForTest: Bool { stream != nil }
    /// Whether the green "Live" pill is showing (running + bound stream).
    var liveVisibleForTest: Bool { !livePill.isHidden }
    /// The output-file basename label ("" when hidden / no file).
    var outputFileLabelForTest: String { outputFileLabel.isHidden ? "" : outputFileLabel.stringValue }
    /// The "Started …" footer line.
    var startedLineForTest: String { startedLabel.stringValue }
    /// Whether the "Ended …" footer line is hidden (true while running).
    var endedHiddenForTest: Bool { endedLabel.isHidden }
    /// Whether the Result/summary section is showing (terminal + summary).
    var summaryVisibleForTest: Bool { !summarySectionStack.isHidden }
}
