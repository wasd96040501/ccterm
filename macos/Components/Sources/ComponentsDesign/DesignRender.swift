import AppKit

/// `ComponentsDesign --render <dir> <width> <light|dark>`: every section built as a page of its own,
/// parked off screen the way `CompositedCapture` parks a window, captured as
/// the window server composites it, written one per section to
/// `<dir>/Design-<section>-<width>-<scheme>.png`, and the process ends. No window is
/// ever on the reader's screen. It is a process of its own so a test can start
/// it with `-AppleLanguages '(en)'`: Foundation fixes the language before any
/// code runs, so only a new process renders the package's words in English.
///
/// A process captures one window once: a second capture in the same process
/// never returns. So the command renders no section itself — it starts itself
/// once per section (`--section <index>`) with the arguments it was given, in
/// turn, and passes on the first failure.
///
/// Exit status: 0 written; 64 the arguments are wrong; 75 no capture could be
/// had now (the display asleep, another capture running); 1 anything else.
enum DesignRender {
    static let unavailableStatus: Int32 = 75

    /// The `--render` arguments of `arguments`, if it has them.
    static func request(from arguments: [String]) -> Request? {
        guard let flag = arguments.firstIndex(of: "--render") else { return nil }
        let rest = Array(arguments.dropFirst(flag + 1))
        guard rest.count >= 3, let width = Double(rest[1]), width >= 200, ["light", "dark"].contains(rest[2]) else {
            FileHandle.standardError.write(Data("usage: ComponentsDesign --render <dir> <width> <light|dark>\n".utf8))
            exit(64)
        }
        var section: Int?
        if let flag = rest.firstIndex(of: "--section"), rest.count > flag + 1 { section = Int(rest[flag + 1]) }
        return Request(directory: rest[0], width: CGFloat(width), isDark: rest[2] == "dark", section: section)
    }

    struct Request {
        var directory: String
        var width: CGFloat
        var isDark: Bool
        /// The one section to render, by index; `nil`: every section, one process each.
        var section: Int?

        func fileName(for section: String) -> String {
            "Design-\(Design.fileSlug(section))-\(Int(width))-\(isDark ? "dark" : "light").png"
        }
    }

    /// Never returns: every section in a process of its own, then exits.
    static func runAll(_ request: Request) -> Never {
        _ = NSApplication.shared
        let count = Design.sections().count
        for index in 0..<count {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = Array(CommandLine.arguments.dropFirst()) + ["--section", "\(index)"]
            do { try process.run() } catch {
                FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
                exit(1)
            }
            // A child that hangs is stopped: every wait has a deadline.
            let deadline = Date(timeIntervalSinceNow: 120)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning {
                process.terminate()
                FileHandle.standardError.write(Data("failed: section \(index) took over 120 s\n".utf8))
                exit(1)
            }
            if process.terminationStatus != 0 { exit(process.terminationStatus) }
        }
        exit(0)
    }

    /// Never returns: renders one section on the main run loop, then exits.
    static func run(_ request: Request, section index: Int) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(
                    atPath: request.directory, withIntermediateDirectories: true)
                let sections = Design.sections()
                guard sections.indices.contains(index) else { exit(64) }
                let section = sections[index]
                let window = CompositedCapture.mount(
                    NSViewController(), size: NSSize(width: request.width, height: 800),
                    appearance: NSAppearance(named: request.isDark ? .darkAqua : .aqua))
                let image = try await render(section, request, in: window)
                let url = URL(fileURLWithPath: request.directory).appendingPathComponent(request.fileName(for: section.title))
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                else { throw CompositedCapture.Failed(description: "the image has no PNG form") }
                try png.write(to: url)
                print(url.path)
                exit(0)
            } catch let error as CompositedCapture.Unavailable {
                FileHandle.standardError.write(Data("unavailable: \(error)\n".utf8))
                exit(unavailableStatus)
            } catch {
                FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
        exit(1)
    }

    /// `section` at `width`, as tall as it is: laid out once at a window's
    /// height, then the window grown to its.
    @MainActor
    private static func render(
        _ section: DesignPageViewController.Section, _ request: Request, in window: NSWindow
    ) async throws -> CGImage {
        let page = DesignPageViewController(sections: [section], showsHeader: false)
        window.contentViewController = page
        window.setContentSize(NSSize(width: request.width, height: 800))
        window.layoutIfNeeded()
        guard let scroll = page.view as? NSScrollView, let document = scroll.documentView else {
            throw CompositedCapture.Failed(description: "the page has no document view")
        }
        let height = document.fittingSize.height
        window.setContentSize(NSSize(width: request.width, height: max(height, 200)))
        window.layoutIfNeeded()
        // Past the scrollers' flash on first showing.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return try await CompositedCapture.image(of: window)
    }
}
