import Foundation

/// What the About window shows: the product's name and build, as the app read
/// them. The window's title arrives worded, as the app's menu words it.
public struct AboutContent: Equatable, Sendable {
    public var name: String
    public var windowTitle: String
    public var version: String
    public var build: String
    public var commit: String

    public init(name: String, windowTitle: String, version: String, build: String, commit: String) {
        self.name = name
        self.windowTitle = windowTitle
        self.version = version
        self.build = build
        self.commit = commit
    }
}
