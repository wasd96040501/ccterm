import AppKit
import ExactListTestSupport

// `make record-list [FILTER=<part of a name>]`: records every `DemoRecording`
// whose name contains the filter. An executable, not a test: TCC attributes
// `xctest`, which lives inside Xcode.app, to Xcode, so a test would need its
// own Screen Recording grant; this runs as the terminal that launched it.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let filter = CommandLine.arguments.dropFirst().first ?? ""
    Task { @MainActor in
        guard #available(macOS 14, *) else {
            print("Recordings need ScreenCaptureKit: macOS 14 or later.")
            exit(1)
        }
        let chosen = DemoRecording.all.filter { filter.isEmpty || $0.name.contains(filter) }
        guard !chosen.isEmpty else {
            print("No recording matches \"\(filter)\". Names: \(DemoRecording.all.map(\.name).joined(separator: ", "))")
            exit(1)
        }
        for recording in chosen {
            do {
                let result = try await recording.record()
                print("\(recording.name): \(result.frameCount) frames → \(result.directory.path)")
            } catch {
                print("\(recording.name): \(error)")
                exit(1)
            }
        }
        exit(0)
    }
    app.run()
}
