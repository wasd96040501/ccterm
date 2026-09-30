import AppKit

/// One call the list made into its data source or delegate, as `RecordingHost`
/// logs it. The log is the oracle for L3, L4, L7, P2, P3, U5, U6, W6 and G7.
public enum HostCall: Equatable {
    case numberOfRows
    case heightOfRow(Int, width: CGFloat)
    case customSpacingAboveRow(Int)
    case viewForRow(Int)
    case didRemove(ObjectIdentifier, row: Int)
    case didChangeTailFollowing(Bool)
    case doCommand(Selector)
}
