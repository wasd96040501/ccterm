import Foundation

/// An image, either embedded or referenced by URL.
public struct ImageBlock: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Base64-encoded bytes and their media type (`image/png`, …).
        case base64(mediaType: String, data: String)
        case url(String)
        case unknown(JSONValue)
    }

    public var source: Source

    public init(source: Source) { self.source = source }

    /// An embedded image from raw bytes.
    public init(data: Data, mediaType: String) {
        self.source = .base64(mediaType: mediaType, data: data.base64EncodedString())
    }
}
