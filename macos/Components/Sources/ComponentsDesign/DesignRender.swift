import AppKit

/// `ComponentsDesign --render <dir> <width> <light|dark>`: the page built,
/// parked off screen the way `CompositedCapture` parks a window, captured as
/// the window server composites it, written to
/// `<dir>/Design-<width>-<scheme>.png`, and the process ends. No window is
/// ever on the reader's screen. It is a process of its own so a test can start
/// it with `-AppleLanguages '(en)'`: Foundation fixes the language before any
/// code runs, so only a new process renders the package's words in English.
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
        return Request(directory: rest[0], width: CGFloat(width), isDark: rest[2] == "dark")
    }

    struct Request {
        var directory: String
        var width: CGFloat
        var isDark: Bool

        var fileName: String { "Design-\(Int(width))-\(isDark ? "dark" : "light").png" }
    }

    /// Never returns: renders on the main run loop, then exits.
    static func run(_ request: Request) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let image = try await render(request)
                let url = URL(fileURLWithPath: request.directory).appendingPathComponent(request.fileName)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw CompositedCapture.Failed(description: "the image has no PNG form")
                }
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

    /// The page at `width`, as tall as it is: laid out once at a window's
    /// height, then the window grown to the page's.
    @MainActor
    private static func render(_ request: Request) async throws -> CGImage {
        let page = DesignPageViewController(sections: Design.sections())
        let appearance = NSAppearance(named: request.isDark ? .darkAqua : .aqua)
        let window = CompositedCapture.mount(page, size: NSSize(width: request.width, height: 800), appearance: appearance)
        window.layoutIfNeeded()
        guard let scroll = page.view as? NSScrollView, let document = scroll.documentView else {
            throw CompositedCapture.Failed(description: "the page has no document view")
        }
        let height = document.fittingSize.height
        window.setContentSize(NSSize(width: request.width, height: max(height, 200)))
        window.layoutIfNeeded()
        // Past the scrollers' flash on first showing.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return try await CompositedCapture.image(of: window)
    }
}
