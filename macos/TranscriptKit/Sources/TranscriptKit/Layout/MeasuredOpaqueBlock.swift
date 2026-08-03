import AppKit

/// A block with no selectable content — a rule, an image, a decoration. Draws,
/// indexes to nothing, copies as nothing.
///
/// A protocol rather than four empty methods repeated per type, so that "this
/// one is not selectable" is a declaration at the conformance rather than
/// something a reader infers from four empty bodies.
protocol MeasuredOpaqueBlock: MeasuredBlock {}

extension MeasuredOpaqueBlock {
    var length: Int { 0 }
    func index(at point: CGPoint) -> Int { 0 }
    func rects(from: Int, to: Int) -> [CGRect] { [] }
    func text(from: Int, to: Int) -> String { "" }
    func wordRange(at index: Int) -> Range<Int> { index..<index }
    func paragraphRange(at index: Int) -> Range<Int> { index..<index }
}
