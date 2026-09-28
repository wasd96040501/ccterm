import Foundation

extension Tools {
    /// Asks the user multiple-choice questions. Answer it through its
    /// ``PermissionRequest``: allow with an `updatedInput` that adds an
    /// `answers` object (question text → chosen label or labels).
    public enum AskUserQuestion: ToolDefinition {
        public static let name = "AskUserQuestion"

        public struct Input: Sendable, Equatable, Decodable {
            public var questions: [Question]

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                questions = try c.required([Question].self, "questions")
            }
        }

        public struct Question: Sendable, Equatable, Decodable {
            public var question: String
            /// A short label for the question, e.g. `"Auth method"`.
            public var header: String
            public var options: [Option]
            public var multiSelect: Bool

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                question = try c.required(String.self, "question")
                header = c.lenient(String.self, "header") ?? ""
                options = c.lenientArray(Option.self, "options") ?? []
                multiSelect = c.lenientBool("multiSelect") ?? false
            }
        }

        public struct Option: Sendable, Equatable, Decodable {
            public var label: String
            public var description: String
            /// Optional content to show when the option is focused.
            public var preview: String?

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                label = try c.required(String.self, "label")
                description = c.lenient(String.self, "description") ?? ""
                preview = c.lenient(String.self, "preview")
            }
        }

        public struct Output: Sendable, Equatable, Decodable {
            public var questions: [Question]
            /// Question text → the answer given.
            public var answers: [String: String]

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                questions = c.lenientArray(Question.self, "questions") ?? []
                answers = c.lenient([String: String].self, "answers") ?? [:]
            }
        }
    }
}
