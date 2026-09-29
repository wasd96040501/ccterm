import Foundation

/// Runs `ExactListProbe` in a child process and reports how it ended (SPEC
/// §13, programmer errors).
///
/// The probe is built beside the test bundle, since the test target depends
/// on it.
public enum ProbeRunner {

    public struct Outcome {
        /// Whether the child died on a signal (a trap) rather than exiting.
        public let trapped: Bool
        public let status: Int32
        public let standardError: String
    }

    /// Runs the probe with `scenario` and waits for it to end.
    public static func run(_ scenario: String) throws -> Outcome {
        guard let bundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) else {
            preconditionFailure("ProbeRunner runs only inside a test bundle")
        }
        let probe = URL(fileURLWithPath: bundle.bundlePath).deletingLastPathComponent()
            .appendingPathComponent("ExactListProbe")
        let process = Process()
        process.executableURL = probe
        process.arguments = [scenario]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Outcome(
            trapped: process.terminationReason == .uncaughtSignal, status: process.terminationStatus,
            standardError: String(decoding: data, as: UTF8.self))
    }
}
