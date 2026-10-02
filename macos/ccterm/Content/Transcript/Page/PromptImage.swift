import AgentSDK
import Foundation
import ImageIO

/// A picture pasted into a prompt (design/transcript/05-local.md): its bytes,
/// read off the transcript, and what the jump bar says of it — never an
/// `NSImage`, so a page stays a plain value built off the main actor.
nonisolated struct PromptImage: Sendable, Equatable, Identifiable {
    /// What opens it beside: the prompt's entry and its number.
    let id: String
    /// *Image N*: the CLI's `imagePasteIds` — a counter across the session,
    /// so a prompt's only image can be 2.
    let number: Int
    let mediaType: String
    let data: Data
    /// Pixels.
    let width: Int
    let height: Int

    /// *Image 2*, in the tab and the jump bar.
    var title: String { String(localized: "Image \(number)") }

    /// *1280 × 720*.
    var dimensions: String { "\(width) × \(height)" }

    /// *PNG*: the media type's subtype, capitalised.
    var format: String {
        let subtype = mediaType.split(separator: "/").last.map(String.init) ?? mediaType
        return subtype.uppercased()
    }

    var aspectRatio: Double { height == 0 ? 1 : Double(width) / Double(height) }

    /// The image of `block` as number `number` of the prompt `entryID`; `nil`
    /// for one that is not embedded or whose bytes can't be read — the CLI
    /// keeps only pictures it could decode.
    init?(_ block: ImageBlock, number: Int, entryID: String) {
        guard case .base64(let mediaType, let encoded) = block.source,
            let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return nil }
        self.id = Self.id(entryID: entryID, number: number)
        self.number = number
        self.mediaType = mediaType
        self.data = data
        self.width = width
        self.height = height
    }

    static func id(entryID: String, number: Int) -> String { "\(entryID).image.\(number)" }
}
