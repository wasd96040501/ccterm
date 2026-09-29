import Foundation

/// Edits made in the variable list, by row index. The list shows whatever
/// rows it is configured with next.
@MainActor
protocol EnvironmentVariablesViewControllerDelegate: AnyObject {
    func environmentVariables(_ list: EnvironmentVariablesViewController, didToggleAt index: Int)
    func environmentVariables(_ list: EnvironmentVariablesViewController, didSetName name: String, at index: Int)
    func environmentVariables(_ list: EnvironmentVariablesViewController, didSetValue value: String, at index: Int)
    /// + was clicked; returns the new row's index, which the list then edits.
    func environmentVariablesDidAdd(_ list: EnvironmentVariablesViewController) -> Int
    func environmentVariables(_ list: EnvironmentVariablesViewController, didRemoveAt index: Int)
    /// The value to edit at `index` — unmasked, unlike the row's display.
    func environmentVariables(_ list: EnvironmentVariablesViewController, valueAt index: Int) -> String
}
