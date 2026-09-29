/// One programmer error, committed for real (SPEC L9, L10, L12, U3). The raw
/// value is the command-line argument, and the requirement its precondition
/// message must name.
enum ProbeScenario: String, CaseIterable {

    /// L9: an update from inside `heightOfRow`.
    case updateInsideCallback = "L9-callback"

    /// L9: a single-call update on the list inside a batch closure.
    case listCallInsideBatch = "L9-batch"

    /// L10: the data source's count disagrees with what was announced.
    case countMismatch = "L10"

    /// L12: a height that isn't finite.
    case invalidHeight = "L12-height"

    /// L12: a negative `rowSpacing`.
    case negativeSpacing = "L12-spacing"

    /// L12: an update index out of range.
    case indexOutOfRange = "L12-index"

    /// L12: the data source deallocated before the list needs it.
    case deallocatedDataSource = "L12-dealloc"

    /// U3: the batch proxy used after its closure returned.
    case proxyAfterClose = "U3-closed"

    /// The requirement ID the precondition message must carry.
    var requirement: String {
        String(rawValue.prefix { $0 != "-" })
    }
}
