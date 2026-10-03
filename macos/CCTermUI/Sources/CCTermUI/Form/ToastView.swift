import AppKit

/// A short note inside a sheet — what a paste just filled: a dark pill
/// that rises in, stays about two seconds and fades. Its owner pins it;
/// it is hidden between notes.
@MainActor
public final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    /// The note's run; a new note replaces it.
    private var run: Task<Void, Never>?

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.88).cgColor
        label.textColor = .windowBackgroundColor
    }

    /// Shows `text` for 2.8 seconds: in over 0.22, out over the last 0.42.
    public func show(_ text: String) {
        run?.cancel()
        label.stringValue = text
        isHidden = false
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            animator().alphaValue = 1
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -6
            rise.toValue = 0
            rise.duration = 0.22
            rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(rise, forKey: "rise")
        }
        run = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.38))
            guard let self, !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.42
                self.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            isHidden = true
        }
    }
}
