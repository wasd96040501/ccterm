/// How an inserted or removed row enters or leaves (SPEC M9).
///
/// The raw values are `NSTableView.AnimationOptions`' own, so the engine
/// converts with `RowTransition(rawValue: options.rawValue)` and nothing
/// else. Core can't name the AppKit type.
public struct RowTransition: OptionSet, Hashable, Sendable {

    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// `NSTableViewAnimationEffectFade`.
    public static let effectFade = RowTransition(rawValue: 0x1)

    /// `NSTableViewAnimationEffectGap`. Here it is the same as no effect: the
    /// row reveals, and nothing else.
    public static let effectGap = RowTransition(rawValue: 0x2)

    /// `NSTableViewAnimationSlideUp`. The slides share a 4-bit field, so these
    /// four are values rather than independent bits (compare with `slide`).
    public static let slideUp = RowTransition(rawValue: 0x10)

    /// `NSTableViewAnimationSlideDown`.
    public static let slideDown = RowTransition(rawValue: 0x20)

    /// `NSTableViewAnimationSlideLeft`.
    public static let slideLeft = RowTransition(rawValue: 0x30)

    /// `NSTableViewAnimationSlideRight`.
    public static let slideRight = RowTransition(rawValue: 0x40)

    /// The one slide in effect, if any. The slide bits form a field, not a set.
    public var slide: RowTransition? {
        let slide = RowTransition(rawValue: rawValue & 0xF0)
        let slides: [RowTransition] = [.slideUp, .slideDown, .slideLeft, .slideRight]
        return slides.contains(slide) ? slide : nil
    }
}
