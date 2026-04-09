import Foundation

extension String {

    /// Truncates a file path for display, keeping the first level and last two levels.
    /// e.g. "/Users/someone/Documents/GitHub/ccterm" → "/Users/.../GitHub/ccterm"
    /// Paths with 3 or fewer components (after root) are returned as-is.
    func truncatedPath() -> String {
        let components = (self as NSString).pathComponents
        // components for "/Users/someone/Documents/GitHub/ccterm":
        // ["/", "Users", "someone", "Documents", "GitHub", "ccterm"]

        // Filter out the root "/" to get real components
        let realComponents = components.filter { $0 != "/" }
        guard realComponents.count > 3 else { return self }

        let first = realComponents[0]
        let lastTwo = realComponents.suffix(2)
        return "/" + first + "/.../" + lastTwo.joined(separator: "/")
    }
}
