import Foundation

/// CLI feature identifiers.
public enum CLIFeature: String, CaseIterable, Sendable {
    case model  // --model
    case pluginDir  // --plugin-dir
}

/// CLI capability probe result. Decides feature availability from the version number.
public struct CLICapability: Sendable {
    public let version: String  // e.g. "2.1.87"

    /// Minimum version per feature (conservative — taken from the release notes' first mention).
    private static let minVersions: [CLIFeature: (Int, Int, Int)] = [
        .model: (2, 0, 41),
        .pluginDir: (2, 1, 74),
    ]

    public func isAvailable(_ feature: CLIFeature) -> Bool {
        guard let min = Self.minVersions[feature],
            let current = Self.parseVersion(version)
        else { return false }
        return current >= min
    }

    public var availableFeatures: Set<CLIFeature> {
        Set(CLIFeature.allCases.filter { isAvailable($0) })
    }

    /// Probes the installed CLI. Returns nil when the CLI is missing or its version is unparseable.
    public static func detect() async -> CLICapability? {
        guard let binaryPath = BinaryLocator.locate() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }
        guard proc.terminationStatus == 0,
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
            let version = extractVersion(output)
        else { return nil }
        return CLICapability(version: version)
    }

    // MARK: - Private

    /// Extracts "2.1.87" from `"2.1.87 (Claude Code)\n"`.
    private static func extractVersion(_ output: String) -> String? {
        let pattern = #"(\d+\.\d+\.\d+)"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    /// `"2.1.87"` → `(2, 1, 87)`.
    private static func parseVersion(_ str: String) -> (Int, Int, Int)? {
        let parts = str.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }
}

// Tuple comparable
private func >= (lhs: (Int, Int, Int), rhs: (Int, Int, Int)) -> Bool {
    if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
    return lhs.2 >= rhs.2
}
