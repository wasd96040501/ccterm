import SwiftUI
import AppKit

/// NSViewRepresentable wrapping NSTextView for SwiftUI.
/// Supports cursor tracking, key interception, IME, and auto-sizing height.
struct SwiftUITextInputView: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool = true
    var placeholder: String = ""
    var font: NSFont = .systemFont(ofSize: 13)
    var minLines: Int = 2
    var maxLines: Int = 10
    var onTextChanged: ((_ text: String, _ cursorLocation: Int) -> Void)?
    var onCommandReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var keyInterceptor: ((NSEvent) -> Bool)?
    @Binding var isFocused: Bool
    /// Set to reposition cursor after programmatic text replacement. Consumed once applied.
    @Binding var desiredCursorPosition: Int?

    func makeNSView(context: Context) -> InputTextScrollView {
        let scrollView = InputTextScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = InputNSTextView(usingTextLayoutManager: true)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        scrollView.lineHeight = lineHeight
        scrollView.minLines = minLines
        scrollView.maxLines = maxLines
        scrollView.updateIntrinsicHeight()

        let coordinator = context.coordinator
        textView.onCommandReturn = { [weak coordinator] in
            coordinator?.onCommandReturn?()
        }
        textView.onInterceptKeyDown = { [weak coordinator] event in
            coordinator?.keyInterceptor?(event) ?? false
        }
        textView.onMarkedTextChanged = { [weak coordinator] in
            coordinator?.updatePlaceholderVisibility()
            scrollView.updateIntrinsicHeight()
        }
        textView.onFocusChanged = { [weak coordinator] focused in
            coordinator?.handleNativeFocusChange(focused)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: InputTextScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }

        // Update text only if needed (avoid loop with delegate updates)
        // Skip during IME composition: textView.string includes marked text but
        // the binding hasn't been updated yet, so resetting would kill the IME session.
        if textView.string != text, !coordinator.isUpdatingText, !textView.hasMarkedText() {
            coordinator.isUpdatingText = true
            textView.string = text
            coordinator.isUpdatingText = false
            scrollView.updateIntrinsicHeight()
        }

        // Apply programmatic cursor repositioning (e.g. after completion replacement)
        // Skip during IME composition to avoid disrupting marked text.
        // Skip if cursor is already at the desired position to avoid update loops.
        if let pos = desiredCursorPosition, !textView.hasMarkedText() {
            let clamped = min(pos, textView.string.count)
            let current = textView.selectedRange()
            if current.location != clamped || current.length != 0 {
                textView.setSelectedRange(NSRange(location: clamped, length: 0))
            }
            DispatchQueue.main.async { self.desiredCursorPosition = nil }
        }

        textView.isEditable = isEnabled
        textView.isSelectable = true

        coordinator.onTextChanged = onTextChanged
        coordinator.onCommandReturn = onCommandReturn
        coordinator.onEscape = onEscape
        coordinator.keyInterceptor = keyInterceptor

        scrollView.minLines = minLines
        scrollView.maxLines = maxLines

        // Update placeholder
        coordinator.updatePlaceholder(text: text, placeholder: placeholder, font: font)

        // Sync focus state: SwiftUI → AppKit
        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        } else if !isFocused, textView.window?.firstResponder === textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SwiftUITextInputView
        weak var textView: InputNSTextView?
        weak var scrollView: InputTextScrollView?
        var isUpdatingText = false
        var isUpdatingFocus = false

        var onTextChanged: ((_ text: String, _ cursorLocation: Int) -> Void)?
        var onCommandReturn: (() -> Void)?
        var onEscape: (() -> Void)?
        var keyInterceptor: ((NSEvent) -> Bool)?

        init(parent: SwiftUITextInputView) {
            self.parent = parent
            super.init()
        }

        /// Called by InputNSTextView when it gains/loses first responder.
        func handleNativeFocusChange(_ focused: Bool) {
            guard !isUpdatingFocus else { return }
            isUpdatingFocus = true
            parent.isFocused = focused
            isUpdatingFocus = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = textView, !isUpdatingText else { return }
            // Skip IME composing
            if textView.hasMarkedText() { return }
            isUpdatingText = true
            parent.text = textView.string
            isUpdatingText = false
            scrollView?.updateIntrinsicHeight()
            updatePlaceholderVisibility()
            // text 和 cursor 同时回调，保证一致
            let cursor = textView.selectedRange().location
            onTextChanged?(textView.string, cursor)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = textView else { return }
            if textView.hasMarkedText() { return }
            let location = textView.selectedRange().location
            // 纯光标移动（不打字），text 不变，cursor 变
            onTextChanged?(textView.string, location)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onEscape?()
                return true
            }
            return false
        }

        func updatePlaceholder(text: String, placeholder: String, font: NSFont) {
            guard let textView = textView else { return }
            textView.placeholderString = placeholder
            textView.placeholderFont = font
            textView.needsDisplay = true
        }

        func updatePlaceholderVisibility() {
            textView?.needsDisplay = true
        }
    }
}

// MARK: - InputNSTextView

/// Custom NSTextView with key interception support.
final class InputNSTextView: NSTextView {
    var onInterceptKeyDown: ((NSEvent) -> Bool)?
    var onCommandReturn: (() -> Void)?
    var onMarkedTextChanged: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var placeholderString: String = ""
    var placeholderFont: NSFont?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if string.isEmpty, !hasMarkedText(), !placeholderString.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.placeholderTextColor,
                .font: placeholderFont ?? font ?? NSFont.systemFont(ofSize: 13),
            ]
            let origin = NSPoint(
                x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                y: textContainerOrigin.y
            )
            placeholderString.draw(at: origin, withAttributes: attrs)
        }
    }

    override var canBecomeKeyView: Bool { false }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocusChanged?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onFocusChanged?(false) }
        return result
    }

    override func keyDown(with event: NSEvent) {
        // Cmd+Return
        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            onCommandReturn?()
            return
        }

        // Custom key interceptor (skip during IME composition)
        if !hasMarkedText(), let interceptor = onInterceptKeyDown, interceptor(event) {
            return
        }

        // Home / End key handling
        if event.keyCode == 115 { // Home
            setSelectedRange(NSRange(location: 0, length: 0))
            return
        }
        if event.keyCode == 119 { // End
            setSelectedRange(NSRange(location: string.count, length: 0))
            return
        }

        super.keyDown(with: event)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChanged?()
    }

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChanged?()
    }

    override func insertNewline(_ sender: Any?) {
        insertText("\n", replacementRange: selectedRange())
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        (enclosingScrollView as? InputTextScrollView)?.updateIntrinsicHeight()
    }
}

// MARK: - InputTextScrollView

/// NSScrollView subclass that reports intrinsic content size based on text lines.
final class InputTextScrollView: NSScrollView {
    var lineHeight: CGFloat = 20
    var minLines: Int = 2
    var maxLines: Int = 10

    private var currentIntrinsicHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollerStyle = .overlay
        autohidesScrollers = true
        setContentHuggingPriority(.required, for: .vertical)
        CursorGuard.registerTextInput(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        CursorGuard.unregisterTextInput(self)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: currentIntrinsicHeight)
    }

    func updateIntrinsicHeight() {
        guard let textView = documentView as? NSTextView,
              let textLayoutManager = textView.textLayoutManager,
              let textContentManager = textLayoutManager.textContentManager else { return }

        let documentRange = textContentManager.documentRange
        textLayoutManager.ensureLayout(for: documentRange)

        var textHeight: CGFloat = 0
        textLayoutManager.enumerateTextLayoutFragments(
            from: documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            let fragmentBottom = fragment.layoutFragmentFrame.maxY
            if fragmentBottom > textHeight {
                textHeight = fragmentBottom
            }
            return true
        }
        textHeight += textView.textContainerInset.height * 2

        let insetH = textView.textContainerInset.height * 2
        let minHeight = lineHeight * CGFloat(minLines) + insetH
        let maxHeight = lineHeight * CGFloat(maxLines) + insetH
        let clamped = min(max(textHeight, minHeight), maxHeight)

        if abs(currentIntrinsicHeight - clamped) > 0.5 {
            currentIntrinsicHeight = clamped
            invalidateIntrinsicContentSize()
        }
    }
}
