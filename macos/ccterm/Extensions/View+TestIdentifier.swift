import SwiftUI

/// Test-only `accessibilityIdentifier(_:)` wrapper.
///
/// Production code calls `view.testIdentifier("Foo.Bar")` instead of
/// `.accessibilityIdentifier("Foo.Bar")` so the identifier strings live
/// behind a `#if DEBUG` boundary — Release builds ship without the
/// XCUITest chrome. The wrapper is type-stable across configurations
/// (both branches return `some View`), so call sites compile in every
/// build flavor.
///
/// **Conventions** — see `macos/cctermUITests/CLAUDE.md`:
/// - Identifier strings are `"<ComponentName>.<ElementName>"`
///   (e.g. `ChatSearchBar.NextButton`, `InputBar2.SendButton`).
/// - Set on the leaf element, not the outer container — SwiftUI's
///   container propagation would otherwise collapse every descendant
///   to the same id.
/// - Anything UI-test-only (a11y identifiers, debug-only modifiers
///   that mark elements for queries) belongs in a `+TestSupport` /
///   `+TestIdentifier` extension file, wrapped in `#if DEBUG`. Never
///   inline `.accessibilityIdentifier(_:)` in production view bodies.
extension View {
    @ViewBuilder
    func testIdentifier(_ id: String) -> some View {
        #if DEBUG
        accessibilityIdentifier(id)
        #else
        self
        #endif
    }
}
