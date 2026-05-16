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
        #endif
        CCTermApp.main()
    }
}
