import Foundation

/// A slash command the CLI offers.
public struct SlashCommand: Sendable, Equatable {
    public var name: String
    public var description: String
    /// Placeholder text for the arguments, e.g. `<file>`.
    public var argumentHint: String
}

extension SlashCommand: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.name = try c.required(String.self, "name")
        self.description = c.lenient(String.self, "description") ?? ""
        self.argumentHint = c.lenient(String.self, "argumentHint", "argument_hint") ?? ""
    }

    /// The CLI's own shape, which `init(from:)` reads back.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(name, forKey: "name")
        try c.encode(description, forKey: "description")
        try c.encode(argumentHint, forKey: "argumentHint")
    }
}
