import Foundation

/// The CLI's own login — `claude auth status | login | logout`. There is one
/// per CLI config directory; every session the CLI starts without an API
/// key or token of its own runs as it.
public enum Auth {
    /// The login the CLI holds now. The CLI exits 1 when no one is signed in
    /// and still prints the status, so the output is read whatever the exit
    /// code.
    public static func status(configuration: CLIConfiguration = CLIConfiguration()) async throws -> AuthStatus {
        let output = try await run(["status", "--json"], configuration: configuration)
        guard !output.timedOut, let status = try? JSONDecoder().decode(AuthStatus.self, from: output.stdout) else {
            let stderr =
                output.timedOut
                ? "Timed out after \(configuration.timeout ?? 0)s"
                : "Unexpected output: \(String(decoding: output.stdout.prefix(500), as: UTF8.self))"
            throw AgentSDKError.authFailed(exitCode: output.status, stderr: stderr)
        }
        return status
    }

    /// Signs in with a claude.ai subscription. The CLI opens the browser and
    /// waits for the person to approve there; the stream yields the sign-in
    /// page's URL once the CLI prints it on stdout (for opening it again), and
    /// finishes when the login is saved. Cancelling the consuming task, or
    /// dropping the stream, ends the CLI and leaves the previous login in
    /// place.
    public static func login(configuration: CLIConfiguration = CLIConfiguration()) -> AsyncThrowingStream<URL, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let process = try configuration.launch(["auth", "login", "--claudeai"]).makeProcess()
                    let output = try await CLIOutput.run(process, timeout: nil) { text in
                        if let url = browserURL(in: text) { continuation.yield(url) }
                    }
                    guard output.status == 0 else {
                        throw AgentSDKError.authFailed(exitCode: output.status, stderr: output.stderr)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Removes the CLI's login.
    public static func logout(configuration: CLIConfiguration = CLIConfiguration()) async throws {
        let output = try await run(["logout"], configuration: configuration)
        guard output.status == 0 else {
            let stderr = output.timedOut ? "Timed out after \(configuration.timeout ?? 0)s" : output.stderr
            throw AgentSDKError.authFailed(exitCode: output.status, stderr: stderr)
        }
    }

    /// The first `https://` URL in what the CLI printed. The CLI wraps it in
    /// a terminal hyperlink (`ESC ] 8 ; ; <url> BEL`), so it ends at a control
    /// character as well as at a space.
    static func browserURL(in text: String) -> URL? {
        guard let range = text.range(of: #"https://[^\s"'<>\x00-\x1f\x7f]+"#, options: .regularExpression)
        else { return nil }
        return URL(string: String(text[range]))
    }

    private static func run(_ arguments: [String], configuration: CLIConfiguration) async throws -> CLIOutput {
        let process = try await Task.detached { try configuration.launch(["auth"] + arguments).makeProcess() }.value
        return try await CLIOutput.run(process, timeout: configuration.timeout)
    }
}
