/// One run of a batch, in the new order (SPEC G5).
///
/// A batch is a sequence of these: consecutive old rows that kept their order,
/// a row that moved, or rows the batch inserted. Everything that has to skip
/// the rows a batch didn't touch walks runs instead of rows.
enum RowRun: Equatable, Sendable {

    /// Old rows `old..<old + count` at new rows `new..<new + count`, neither
    /// moved nor removed: the surviving rows of M2.
    case kept(old: Int, new: Int, count: Int)

    /// Old row `old`, moved to new row `new` (M10).
    case moved(old: Int, new: Int)

    /// New rows `new..<new + count`, inserted with `transition`.
    case inserted(new: Int, count: Int, transition: RowTransition)

    /// The first new row of the run.
    var newStart: Int {
        switch self {
        case .kept(_, let new, _), .moved(_, let new), .inserted(let new, _, _): new
        }
    }

    /// How many rows the run holds.
    var count: Int {
        switch self {
        case .kept(_, _, let count), .inserted(_, let count, _): count
        case .moved: 1
        }
    }
}
