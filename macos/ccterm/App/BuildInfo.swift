import Foundation

enum BuildInfo {
    static var marketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    static var gitCommit: String {
        Bundle.main.infoDictionary?["CCGitCommit"] as? String ?? "unknown"
    }
}
