import Foundation

/// Extended thinking. See ``SessionConfiguration/thinking``.
public enum ThinkingConfig: Sendable {
    case adaptive
    case enabled(budgetTokens: Int)
    case disabled
}
