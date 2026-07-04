import AppKit

/// Bridges the old live-CLI coordinator into the shared
/// `BlockCellViewDelegate` protocol. Every method already exists as a
/// direct instance method with the matching signature (verified in
/// `Transcript2Coordinator.swift`: `toggleFold` @867, `requestUserBubbleSheet`
/// @1097, `requestImagePreview` @1108, `handleGutter` @1507,
/// `hoveredBlockId` @1594, `isLiveScrolling` @1617) — so protocol
/// adoption is purely additive with no method bodies to write here.
///
/// `isLiveScrolling` is `private(set)` on the coord, which already
/// satisfies the protocol's `get`-only requirement.
extension Transcript2Coordinator: BlockCellViewDelegate {}
