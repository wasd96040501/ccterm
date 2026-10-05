import AppKit

/// The contract every `.view` row of a transcript tab keeps, so that one
/// place (`PageRow+View`) can measure and dequeue all of them alike.
///
/// - `height(for:width:)` is asked far more often than a view is made —
///   TranscriptKit measures a working set of rows it never shows — so it is
///   static, answers from the model and the width alone, and builds nothing.
/// - `configure(with:)` is idempotent: a recycled view is rewritten whole,
///   carrying nothing over from the row it showed before.
/// - Events go up through `delegate`, by id; a row view never acts itself.
@MainActor
public protocol PageRowView: NSView {
    associatedtype Model

    init()

    static func height(for model: Model, width: CGFloat) -> CGFloat

    func configure(with model: Model)

    var delegate: PageRowViewDelegate? { get set }
}

extension PageRowView {
    /// One pool per view type (`TranscriptView.makeView(withIdentifier:make:)`).
    public static var reuseIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(String(describing: Self.self))
    }
}
