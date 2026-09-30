/// One programmer error, committed for real (SPEC L9, L10, L12). The raw
/// value is the command-line argument, and the requirement its precondition
/// message must name.
enum ProbeScenario: String, CaseIterable {

    /// L9: an update from inside `heightOfRow`.
    case updateInsideCallback = "L9-callback"

    /// L9: `reloadData()` on the list inside a batch closure.
    case reloadInsideBatch = "L9-reload"

    /// L9: a scroll method from inside `heightOfRow`.
    case scrollInsideCallback = "L9-scroll"

    /// L9: a geometry query on the list inside a batch closure.
    case queryInsideBatch = "L9-query"

    /// L10: the data source's count disagrees with what was announced.
    case countMismatch = "L10"

    /// L12: a height that isn't finite.
    case invalidHeight = "L12-height"

    /// L12: a height of 0.
    case zeroHeight = "L12-height-zero"

    /// L12: a negative `rowSpacing`.
    case negativeSpacing = "L12-spacing"

    /// L12: a `rowSpacing` that isn't finite, set before the load point.
    case infiniteSpacing = "L12-spacing-inf"

    /// L12: an update index out of range.
    case indexOutOfRange = "L12-index"

    /// L12: `.row(r)` anchoring out of range.
    case anchorOutOfRange = "L12-anchor"

    /// L12: a scroll request out of range.
    case scrollOutOfRange = "L12-scroll"

    /// L12: a scroll request recorded before the load point, out of range when
    /// the load applies it.
    case pendingScrollOutOfRange = "L12-scroll-pending"

    /// L12: the data source deallocated before the list needs it.
    case deallocatedDataSource = "L12-dealloc"

    /// L12: the host deallocated before the load point reaches it.
    case deallocatedBeforeLoad = "L12-dealloc-load"

    /// L12: the delegate deallocated before a scroll mounts new rows.
    case deallocatedBeforePlacement = "L12-dealloc-placement"

    /// The requirement ID the precondition message must carry.
    var requirement: String {
        String(rawValue.prefix { $0 != "-" })
    }

    /// Whether the probe loads the list before committing the scenario. The
    /// scenarios about the load point itself commit theirs first.
    var loadsFirst: Bool {
        switch self {
        case .infiniteSpacing, .pendingScrollOutOfRange, .deallocatedBeforeLoad: false
        default: true
        }
    }
}
