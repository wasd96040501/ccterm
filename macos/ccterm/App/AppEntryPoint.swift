import AppKit
import Foundation
import SwiftUI

/// Process entry point. The **only `@main` type**.
///
/// Normally forwards to `CCTermApp.main()` (SwiftUI app). In DEBUG, if the
/// `CCTERM_RUN_AS_MOCK_CLI=1` environment variable is set, runs
/// `MockCLIRunner.run()` instead (reads stdin / writes line-delimited JSON to
/// stdout, matching the real claude CLI protocol) — used as the "mock claude
/// subprocess" for UI tests.
///
/// Why this wrapper: the UI test mock CLI needs an executable binary; reusing
/// the current ccterm binary (with a mock-path branch in the child process)
/// avoids maintaining a separate SPM target. The parent stays a normal SwiftUI
/// app; the child forks to `MockCLIRunner.run()` immediately at main, never
/// touching SwiftUI / CoreData.
@main
struct AppEntryPoint {
    static func main() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CCTERM_RUN_AS_MOCK_CLI"] == "1" {
            MockCLIRunner.run()
        }
        // Unit-test host. xcodebuild spawned us via the test runner with
        // `TEST_HOST` pointing at this binary; XCTest will load the test
        // bundle once we hand control to a runloop. Start a UI-less
        // `NSApplication` (no dock icon, no windows, no SwiftUI tree) so
        // the test bundle has a runloop to run on without bringing the
        // real app forward during parallel CI runs. Returning here would
        // exit the process before XCTest could establish its connection.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            app.run()
            return
        }
        #endif
        CCTermApp.main()
    }
}
