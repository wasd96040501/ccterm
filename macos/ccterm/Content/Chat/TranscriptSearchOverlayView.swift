import AppKit
import SwiftUI

/// Floating search field overlay used by `ChatHistoryView`. Wraps an
/// `NSSearchField` so XCUITest still finds it via
/// `app.searchFields.firstMatch` (a SwiftUI `TextField` would surface as
/// an `XCUIElement` of type `textField`) and so the native macOS magnifier
/// + clear-button affordances come for free.
///
/// Why not `.searchable(placement: .toolbar)`? A window toolbar reserves a
/// ~52pt vertical band that `.ignoresSafeArea(edges: .top)` cannot fully
/// reclaim on macOS, which pushes the transcript below the window chrome.
/// Floating the field as an `.overlay(alignment: .top)` instead keeps the
/// transcript truly flush to the window's top edge while the search field
/// reads as a chromeless affordance over the top fade-blur scrim.
///
/// Key handling lives in the `NSSearchFieldDelegate`:
///
/// - Plain `Return` is delivered via the cell's `action`, which calls
///   `onNext` (advance to the next match).
/// - `Shift+Return` arrives as `insertNewline(_:)` through
///   `control(_:textView:doCommandBy:)`; modifiers are read from
///   `NSApp.currentEvent`. We treat shift as the "previous" signal and
///   swallow the command so AppKit doesn't insert a literal newline.
///
/// Focus is bidirectional via a `@Binding`: `isFocused = true` makes the
/// field first responder (driven by `TranscriptSearchBus.requestFocus`
/// for ⌘F), and the delegate's `controlTextDidBeginEditing` /
/// `controlTextDidEndEditing` flip the binding back so SwiftUI's state
/// matches the AppKit reality.
struct TranscriptSearchOverlayView: View {
    @Binding var query: String
    @Binding var isFocused: Bool
    var onNext: () -> Void
    var onPrevious: () -> Void

    var body: some View {
        NSSearchFieldRepresentable(
            text: $query,
            isFocused: $isFocused,
            placeholder: String(localized: "Find in transcript"),
            onNext: onNext,
            onPrevious: onPrevious
        )
        .frame(width: 220)
    }
}

private struct NSSearchFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let onNext: () -> Void
    let onPrevious: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(frame: .zero)
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submitted(_:))
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Drive focus from SwiftUI → AppKit. The reverse direction is
        // handled by the delegate's begin / end editing notifications.
        // The dispatch defers the responder change one runloop tick so
        // the AppKit window has finished its own layout pass for this
        // frame (otherwise the first ⌘F lands on a window that hasn't
        // yet been made key, and `makeFirstResponder` silently fails).
        if isFocused {
            let isAlreadyFocused = nsView.window?.firstResponder == nsView.currentEditor()
            if !isAlreadyFocused {
                DispatchQueue.main.async {
                    nsView.window?.makeFirstResponder(nsView)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NSSearchFieldRepresentable

        init(_ parent: NSSearchFieldRepresentable) {
            self.parent = parent
        }

        // MARK: NSTextFieldDelegate

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            // Push the typed value back through the binding so the
            // search controller sees every keystroke (search is
            // incremental, not on submit).
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func controlTextDidEndEditing(_: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }

        /// Returns `true` to swallow the command (we've handled it),
        /// `false` to let AppKit run its default. We need the default
        /// for everything except `Shift+Return`, which would otherwise
        /// route into either `insertNewline:` (a no-op on the single-
        /// line field) or `insertNewlineIgnoringFieldEditor:`. The
        /// search field's `action` (wired to `onNext`) fires for plain
        /// Return separately — see `submitted(_:)`.
        func control(
            _: NSControl,
            textView _: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:))
            else { return false }
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            if mods.contains(.shift) {
                parent.onPrevious()
                return true
            }
            return false
        }

        // MARK: Action

        @objc func submitted(_: NSSearchField) {
            // Action fires on plain Return. Shift+Return is intercepted
            // by `control(_:textView:doCommandBy:)` above and never
            // reaches the action target.
            parent.onNext()
        }
    }
}
