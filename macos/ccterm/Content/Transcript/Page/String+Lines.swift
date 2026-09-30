import Foundation

nonisolated extension String {
    /// Its lines, as a file has them: the newline that ends the last does not
    /// start another, so `"a\nb\n"` is two lines — how every stat and every
    /// numbered line in the transcript counts.
    var lines: [String] {
        guard !isEmpty else { return [] }
        var lines = components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
