import Foundation

/// Reasoning effort (`--effort`, and `effortLevel` in settings).
public enum Effort: String, Sendable, CaseIterable {
    case low
    case medium
    case high
    case xhigh
    case max
}
