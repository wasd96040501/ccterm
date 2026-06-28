import CoreGraphics
import Foundation

/// Pure geometry / animation constants for the AskUserQuestion wizard
/// (migration plan §4.5), lifted verbatim from the SwiftUI
/// `PermissionAskUserQuestionCardBody` so the AppKit row / header / other views
/// share one source of truth and a measurement test can assert them without
/// mounting a view.
///
/// All numbers cite their original line in
/// `PermissionAskUserQuestionCardBody.swift`.
enum AskUserQuestionLayout {

    // MARK: - Row geometry

    /// Shared row height. For option rows + the collapsed Other button this is
    /// a FLOOR (`minHeight`) combined with `optionVPadding` so a 2-line
    /// description grows the row (SwiftUI `.frame(minHeight:)`, `:548`); for the
    /// Other EDITING field it is a FIXED height so collapsed↔editing renders at
    /// one height with no jump (SwiftUI `.frame(height:)`, `:290`).
    static let rowHeight: CGFloat = 36
    /// Option-row vertical padding around the label/desc column — SwiftUI
    /// `.padding(.vertical, 8)` on `AskOptionRowStyle` (`:546`). Combined with
    /// the `minHeight` floor so a single-line row is 36pt and a 2-line-desc row
    /// grows.
    static let optionVPadding: CGFloat = 8
    /// Option / Other row corner radius, `.continuous` (`:46`).
    static let rowCornerRadius: CGFloat = 8
    /// Row horizontal padding (`:47`).
    static let rowHPadding: CGFloat = 12
    /// Spacing between option rows + the Other row (`:48,186`).
    static let rowSpacing: CGFloat = 6
    /// Outer VStack spacing: header → options → decision buttons (`:49,98`).
    static let groupSpacing: CGFloat = 12

    // MARK: - Row content

    /// Option-row HStack content spacing (label/desc column ↔ ✓) (`:200`).
    static let rowContentSpacing: CGFloat = 8
    /// Option label / desc VStack spacing (`:201`).
    static let optionTextSpacing: CGFloat = 1
    /// Option label font size (`:203`).
    static let optionLabelSize: CGFloat = 13
    /// Option description font size (`:207`).
    static let optionDescriptionSize: CGFloat = 11
    /// Trailing selection checkmark font size (`:215`).
    static let checkmarkSize: CGFloat = 11

    // MARK: - Header

    /// Header inner VStack spacing: chip row → question text (`:132`).
    static let headerInnerSpacing: CGFloat = 6
    /// Chip-row HStack spacing (`:134`).
    static let chipRowSpacing: CGFloat = 8
    /// Back-chevron font size (`:138`).
    static let chevronSize: CGFloat = 11
    /// Back-chevron frame side (`:140`).
    static let chevronFrame: CGFloat = 18
    /// Progress / header chip font size (`:150,161`).
    static let chipFontSize: CGFloat = 11
    /// Chip horizontal padding (`:152,163`).
    static let chipHPadding: CGFloat = 6
    /// Chip vertical padding (`:153,164`).
    static let chipVPadding: CGFloat = 2
    /// Chip corner radius, `.continuous` (`:155,166`).
    static let chipCornerRadius: CGFloat = 4
    /// Question text font size (`:174`).
    static let questionTextSize: CGFloat = 13

    // MARK: - Animation (D5 — opacity / color only; no transform/scale)

    /// Hover fill cross-fade — `.linear(duration: 0.08)` (`:565`).
    static let hoverAnimDuration: TimeInterval = 0.08
    /// Press fill cross-fade — `.linear(duration: 0.06)` (`:566`).
    static let pressAnimDuration: TimeInterval = 0.06

    // MARK: - Fallback

    /// Fallback VStack spacing (`:474`).
    static let fallbackSpacing: CGFloat = 12
    /// Fallback inner label spacing (`:475`).
    static let fallbackInnerSpacing: CGFloat = 4
    /// Fallback title font size (`:477`).
    static let fallbackTitleSize: CGFloat = 12
    /// Fallback subtitle font size (`:480`).
    static let fallbackSubtitleSize: CGFloat = 11
}
