import AgentSDK
import Foundation

/// Tells whether a launch works, by running it with `--version`. Each
/// configuration is probed once: a second ask gets the answer, and asks made
/// while it runs share the run.
@MainActor
final class LaunchCheckService {
    typealias Probe = @Sendable (CLIConfiguration) async throws -> CLIVersion

    private let probe: Probe
    private let timeout: TimeInterval
    private var results: [CLIConfiguration: LaunchCheck] = [:]
    private var running: [CLIConfiguration: Task<LaunchCheck, Never>] = [:]

    /// `probe`: runs a configuration; `timeout`: how long it gets, in seconds.
    init(timeout: TimeInterval = 10, probe: @escaping Probe = { try await CLIVersion.probe($0) }) {
        self.timeout = timeout
        self.probe = probe
    }

    /// The answer for `configuration`, running the probe if nobody has.
    func check(_ configuration: CLIConfiguration) async -> LaunchCheck {
        if let result = results[configuration] { return result }
        if let task = running[configuration] { return await task.value }
        var bounded = configuration
        bounded.timeout = timeout
        let probe = probe
        let task = Task { () -> LaunchCheck in
            let result: LaunchCheck
            do {
                result = .valid(try await probe(bounded))
            } catch {
                appLog(.info, "LaunchCheckService", "check failed — \(error.localizedDescription)")
                result = .invalid(Self.message(for: error))
            }
            results[configuration] = result
            running[configuration] = nil
            return result
        }
        running[configuration] = task
        return await task.value
    }

    /// The answer for `configuration` if it is known; never runs anything.
    func cached(_ configuration: CLIConfiguration) -> LaunchCheck? {
        results[configuration]
    }

    /// A failure as a few words for a form row.
    static func message(for error: Error) -> String {
        switch error as? AgentSDKError {
        case .binaryNotFound:
            return String(localized: "Not found")
        case .noVersion:
            return String(localized: "Didn't print a version")
        case .launchFailed:
            return String(localized: "Couldn't start")
        case .versionFailed(let exitCode, let message):
            if message.hasPrefix("Timed out") { return String(localized: "Timed out") }
            return message.isEmpty ? String(localized: "Exited with code \(Int(exitCode))") : message
        default:
            return error.localizedDescription
        }
    }
}
