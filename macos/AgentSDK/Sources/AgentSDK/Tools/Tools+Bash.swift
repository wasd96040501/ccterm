import Foundation

extension Tools {
    /// Runs a shell command. A non-zero exit is a ``ToolOutcome/failure(_:)``
    /// carrying the combined output, not an ``Output``.
    public enum Bash: ToolDefinition {
        public static let name = "Bash"

        public struct Input: Sendable, Equatable, Decodable {
            public var command: String
            /// The model's one-line summary of what the command does.
            public var description: String?
            /// Milliseconds.
            public var timeout: Int?
            public var runInBackground: Bool
            public var dangerouslyDisableSandbox: Bool

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                command = try c.required(String.self, "command")
                description = c.lenient(String.self, "description")
                timeout = c.lenientInt("timeout")
                runInBackground = c.lenientBool("run_in_background") ?? false
                dangerouslyDisableSandbox = c.lenientBool("dangerouslyDisableSandbox") ?? false
            }
        }

        public struct Output: Sendable, Equatable, Decodable {
            public var stdout: String
            public var stderr: String
            public var interrupted: Bool
            /// `stdout` holds image data rather than text.
            public var isImage: Bool
            /// Set when the command ran, or was moved, into the background.
            public var backgroundTaskID: String?
            /// A note explaining a meaningful exit code (e.g. `grep` found
            /// nothing).
            public var returnCodeInterpretation: String?
            /// Where the full output went when it was too large to inline.
            public var persistedOutputPath: String?

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                stdout = c.lenient(String.self, "stdout") ?? ""
                stderr = c.lenient(String.self, "stderr") ?? ""
                interrupted = c.lenientBool("interrupted") ?? false
                isImage = c.lenientBool("isImage") ?? false
                backgroundTaskID = c.lenient(String.self, "backgroundTaskId")
                returnCodeInterpretation = c.lenient(String.self, "returnCodeInterpretation")
                persistedOutputPath = c.lenient(String.self, "persistedOutputPath")
            }
        }
    }
}
