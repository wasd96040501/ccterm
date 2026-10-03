import AgentSDK
import DisplayModels
import Foundation
import ImageIO

nonisolated extension PromptImage {
    /// *Image 2*, in the tab and the jump bar.
    var title: String { String(localized: "Image \(number)") }

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
        self.init(
            id: Self.id(entryID: entryID, number: number), number: number, mediaType: mediaType, data: data,
            width: width, height: height)
    }
}
