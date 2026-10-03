import Foundation

/// A picture pasted into a prompt (design/transcript/05-local.md): its bytes,
/// read off the transcript, and what the jump bar says of it — never an
/// `NSImage`, so a page stays a plain value built off the main actor.
public nonisolated struct PromptImage: Sendable, Equatable, Identifiable {
    /// What opens it beside: the prompt's entry and its number.
    public let id: String
    /// *Image N*: the CLI's `imagePasteIds` — a counter across the session,
    /// so a prompt's only image can be 2.
    public let number: Int
    public let mediaType: String
    public let data: Data
    /// Pixels.
    public let width: Int
    public let height: Int

    public init(id: String, number: Int, mediaType: String, data: Data, width: Int, height: Int) {
        self.id = id
        self.number = number
        self.mediaType = mediaType
        self.data = data
        self.width = width
        self.height = height
    }

    /// *1280 × 720*.
    public var dimensions: String { "\(width) × \(height)" }

    /// *PNG*: the media type's subtype, capitalised.
    public var format: String {
        let subtype = mediaType.split(separator: "/").last.map(String.init) ?? mediaType
        return subtype.uppercased()
    }

    public var aspectRatio: Double { height == 0 ? 1 : Double(width) / Double(height) }

    public static func id(entryID: String, number: Int) -> String { "\(entryID).image.\(number)" }
}
