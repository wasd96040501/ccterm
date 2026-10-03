import DisplayModels
import Foundation

extension AboutContent {
    /// The running app's name and build.
    static var current: AboutContent {
        AboutContent(
            name: "ccterm", windowTitle: String(localized: "About ccterm"),
            version: BuildInfo.marketingVersion, build: BuildInfo.buildNumber, commit: BuildInfo.gitCommit)
    }
}
