import Foundation

extension Tools {
    /// Fetches a URL and answers a prompt about its content.
    public enum WebFetch: ToolDefinition {
        public static let name = "WebFetch"

        public struct Input: Sendable, Equatable, Decodable {
            public var url: String
            public var prompt: String

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                url = try c.required(String.self, "url")
                prompt = c.lenient(String.self, "prompt") ?? ""
            }
        }

        public struct Output: Sendable, Equatable, Decodable {
            public var url: String
            /// HTTP status code.
            public var code: Int
            public var codeText: String
            public var bytes: Int
            /// The model's answer to the prompt.
            public var result: String
            public var durationMS: Int

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                url = c.lenient(String.self, "url") ?? ""
                code = c.lenientInt("code") ?? 0
                codeText = c.lenient(String.self, "codeText") ?? ""
                bytes = c.lenientInt("bytes") ?? 0
                result = c.lenient(String.self, "result") ?? ""
                durationMS = c.lenientInt("durationMs") ?? 0
            }
        }
    }

    /// Searches the web.
    public enum WebSearch: ToolDefinition {
        public static let name = "WebSearch"

        public struct Input: Sendable, Equatable, Decodable {
            public var query: String
            public var allowedDomains: [String]
            public var blockedDomains: [String]

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                query = try c.required(String.self, "query")
                allowedDomains = c.lenient([String].self, "allowed_domains") ?? []
                blockedDomains = c.lenient([String].self, "blocked_domains") ?? []
            }
        }

        public struct Output: Sendable, Equatable, Decodable {
            public var query: String
            /// Result links, across all searches.
            public var links: [Link]
            /// The model's commentary between searches.
            public var summaries: [String]
            public var durationSeconds: Double

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                query = c.lenient(String.self, "query") ?? ""
                durationSeconds = c.lenient(Double.self, "durationSeconds") ?? 0
                let results = c.lenient([JSONValue].self, "results") ?? []
                summaries = results.compactMap(\.stringValue)
                links = results.flatMap { result -> [Link] in
                    (result["content"]?.arrayValue ?? []).compactMap { item in
                        guard let url = item["url"]?.stringValue else { return nil }
                        return Link(title: item["title"]?.stringValue ?? url, url: url)
                    }
                }
            }
        }

        public struct Link: Sendable, Equatable {
            public var title: String
            public var url: String
        }
    }
}
