import AVFoundation
import AppKit
import ScreenCaptureKit

/// Records what the window server composites for one window, around one
/// action, for eyes to read frame by frame (SPEC §13, recordings).
///
/// Capture is ScreenCaptureKit's, of that window alone, so the window can sit
/// off screen (`ListStage(size:recordable:)`) and nothing shows on the
/// display. Frames arrive only when the window changed. Each one is timed by
/// when it was displayed, on the clock `CACurrentMediaTime()` reads, so a
/// frame's name says how long after the action it was on screen.
///
/// A recording writes, into `/tmp/exactlist-recordings/<name>/`:
/// - `frames/`: every captured frame as a PNG, the last one before the action
///   first, named by its index and its time from the action;
/// - `sheet.png`: the frame on screen at every 60 Hz tick of a range (the
///   first half second by default), each tile labelled with its time;
/// - `movie.mov`: all of it, at the times it was captured.
///
/// Needs the Screen Recording permission of the app TCC attributes the process
/// to; without it `record` throws `Unavailable`, saying how to grant it. That
/// is why recordings run as an executable from the terminal: `xctest` lives
/// inside Xcode.app and is attributed to Xcode.
@available(macOS 14, *)
@MainActor
public enum WindowRecorder {

    /// Why nothing could be recorded.
    public struct Unavailable: Error, CustomStringConvertible {
        public let description: String
    }

    /// What a recording wrote.
    public struct Recording {
        public let directory: URL
        /// The frames captured, the one before the action included.
        public let frameCount: Int
        public let sheet: URL
        public let movie: URL
    }

    /// Where every recording goes, one directory per name.
    public static let root = URL(fileURLWithPath: "/tmp/exactlist-recordings", isDirectory: true)

    /// Captures `window` from just before `action` until `seconds` after it
    /// (at most 3), then writes the frames, the sheet of `sheet` (seconds from
    /// the action) and the movie. The main run loop runs throughout.
    public static func record(
        _ window: NSWindow, named name: String, seconds: TimeInterval = 1.5,
        sheet: ClosedRange<TimeInterval> = 0...0.5, action: () -> Void
    ) async throws -> Recording {
        precondition(seconds > 0 && seconds <= 3, "a recording is at most 3 s")
        // The preflight can say yes while ScreenCaptureKit says no (measured:
        // for a process TCC attributes to an app without the grant).
        guard CGPreflightScreenCaptureAccess() else { throw Unavailable(description: noPermission) }
        let content: SCShareableContent = try await withCheckedThrowingContinuation { done in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
                if let content {
                    done.resume(returning: content)
                } else if let error = error as NSError?, error.domain == SCStreamErrorDomain,
                    error.code == SCStreamError.Code.userDeclined.rawValue
                {
                    done.resume(throwing: Unavailable(description: noPermission))
                } else {
                    done.resume(throwing: error ?? Unavailable(description: "No shareable content."))
                }
            }
        }
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw Unavailable(description: "The window server doesn't offer window \(window.windowNumber) for capture.")
        }

        let directory = root.appendingPathComponent(name, isDirectory: true)
        let frames = directory.appendingPathComponent("frames", isDirectory: true)
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(
            "exactlist-recording-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: raw) }

        let scale = window.backingScaleFactor
        let configuration = SCStreamConfiguration()
        configuration.width = Int((window.frame.width * scale).rounded())
        configuration.height = Int((window.frame.height * scale).rounded())
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 8
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let sink = Sink(directory: raw)
        let stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        try await stream.startCapture()

        // The window as it was: the first frame is always complete.
        let deadline = CACurrentMediaTime() + 2
        while sink.count == 0 && CACurrentMediaTime() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let zero = CACurrentMediaTime()
        action()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        try await stream.stopCapture()
        let captured = sink.drain().map { Frame(raw: $0, time: $0.time - zero) }

        // The last frame before the action, then everything after it.
        let before = captured.last { $0.time < 0 }
        let shown = (before.map { [$0] } ?? []) + captured.filter { $0.time >= 0 }
        guard !shown.isEmpty else { throw Unavailable(description: "No frame was captured.") }

        for (index, frame) in shown.enumerated() {
            let file = frames.appendingPathComponent(
                String(format: "%03d_%+07.1fms.png", index, frame.time * 1000))
            try writePNG(frame.image(), to: file)
        }
        let sheetURL = directory.appendingPathComponent("sheet.png")
        try writePNG(makeSheet(of: shown, range: sheet, scale: scale), to: sheetURL)
        let movieURL = directory.appendingPathComponent("movie.mov")
        try await writeMovie(of: shown, until: seconds, to: movieURL)
        return Recording(directory: directory, frameCount: shown.count, sheet: sheetURL, movie: movieURL)
    }

    // MARK: - Private

    nonisolated private static let noPermission = """
        No Screen Recording permission. It belongs to the app the recording runs as: the terminal that \
        runs `make record-list`. Grant it in System Settings › Privacy & Security › Screen & System Audio \
        Recording, restart the terminal, and run again.
        """

    /// One captured frame's pixels, kept on disk until the capture ends so a
    /// long one costs no memory.
    private struct RawFrame: Sendable {
        var time: CFTimeInterval
        var file: URL
        var width: Int
        var height: Int
        var bytesPerRow: Int
    }

    /// A captured frame, timed from the action.
    private struct Frame {
        var raw: RawFrame
        var time: CFTimeInterval

        func image() throws -> CGImage {
            let data = try Data(contentsOf: raw.file)
            guard let provider = CGDataProvider(data: data as CFData),
                let image = CGImage(
                    width: raw.width, height: raw.height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: raw.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(
                        rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                            | CGImageAlphaInfo.premultipliedFirst.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { throw Unavailable(description: "Frame \(raw.file.lastPathComponent) is unreadable.") }
            return image
        }
    }

    /// The stream's output: every complete frame, copied to a file on the
    /// sample queue, so the stream's buffers go straight back to it.
    private final class Sink: NSObject, SCStreamOutput, @unchecked Sendable {

        let queue = DispatchQueue(label: "WindowRecorder.samples")

        init(directory: URL) {
            self.directory = directory
        }

        var count: Int { lock.withLock { frames.count } }

        /// Waits for the frames in flight, and hands over all of them.
        func drain() -> [RawFrame] {
            queue.sync {}
            return lock.withLock { frames }.sorted { $0.time < $1.time }
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType)
        {
            guard type == .screen, sampleBuffer.isValid,
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                let info = attachments.first,
                let status = info[.status] as? Int, SCFrameStatus(rawValue: status) == .complete,
                let pixels = sampleBuffer.imageBuffer
            else { return }
            let time: CFTimeInterval
            if let displayed = info[.displayTime] as? UInt64 {
                time = Self.seconds(machTime: displayed)
            } else {
                time = sampleBuffer.presentationTimeStamp.seconds
            }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
            let height = CVPixelBufferGetHeight(pixels)
            let file = directory.appendingPathComponent("\(written).bgra")
            written += 1
            guard (try? Data(bytes: base, count: bytesPerRow * height).write(to: file)) != nil else { return }
            let frame = RawFrame(
                time: time, file: file, width: CVPixelBufferGetWidth(pixels), height: height,
                bytesPerRow: bytesPerRow)
            lock.withLock { frames.append(frame) }
        }

        private let directory: URL
        private let lock = NSLock()
        private var frames: [RawFrame] = []
        /// Touched on `queue` only.
        private var written = 0

        /// The clock `CACurrentMediaTime()` reads.
        private static func seconds(machTime: UInt64) -> CFTimeInterval {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            return Double(machTime) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw Unavailable(description: "Can't write \(url.path).")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Unavailable(description: "Can't write \(url.path).")
        }
    }

    /// A grid of what was on screen at each 60 Hz tick of `range`, after a tile
    /// of the frame before the action. Tiles are a third of the window's size
    /// in points.
    private static func makeSheet(
        of frames: [Frame], range: ClosedRange<TimeInterval>, scale: CGFloat
    ) throws
        -> CGImage
    {
        let ticks = Int(((range.upperBound - range.lowerBound) * 60).rounded(.down))
        var tiles: [(label: String, frame: Frame)] = []
        if let first = frames.first, first.time < 0 { tiles.append(("before", first)) }
        for tick in 0...ticks {
            let time = range.lowerBound + Double(tick) / 60
            guard let frame = frames.last(where: { $0.time <= time }) ?? frames.first else { continue }
            let index = frames.firstIndex { $0.time == frame.time } ?? 0
            tiles.append((String(format: "%+.1f ms  #%03d", time * 1000, index), frame))
        }
        let sample = try frames[0].image()
        let tileWidth = CGFloat(sample.width) / scale / 3
        let tileHeight = CGFloat(sample.height) / scale / 3
        let label: CGFloat = 16
        let columns = 6
        let rows = (tiles.count + columns - 1) / columns
        let width = Int(tileWidth * CGFloat(columns) * scale)
        let height = Int((tileHeight + label) * CGFloat(rows) * scale)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw Unavailable(description: "Can't draw the sheet.") }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale))
        let pageHeight = CGFloat(height) / scale
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, tile) in tiles.enumerated() {
            let x = CGFloat(index % columns) * tileWidth
            let top = pageHeight - CGFloat(index / columns) * (tileHeight + label)
            let image = try tile.frame.image()
            context.draw(image, in: CGRect(x: x, y: top - label - tileHeight, width: tileWidth, height: tileHeight))
            context.setStrokeColor(NSColor.systemRed.cgColor)
            context.setLineWidth(0.5)
            context.stroke(CGRect(x: x, y: top - label - tileHeight, width: tileWidth, height: tileHeight))
            NSAttributedString(
                string: tile.label,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: NSColor.black,
                ]
            ).draw(at: NSPoint(x: x + 4, y: top - label + 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let sheet = context.makeImage() else { throw Unavailable(description: "Can't draw the sheet.") }
        return sheet
    }

    /// H.264 at the captured size, each frame at its time from the first.
    private static func writeMovie(of frames: [Frame], until end: TimeInterval, to url: URL) async throws {
        let width = frames[0].raw.width
        let height = frames[0].raw.height
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Unavailable(description: "Can't write the movie.") }
        let start = frames[0].time
        writer.startSession(atSourceTime: .zero)
        var last = -1.0
        for frame in frames {
            let offset = frame.time - start
            guard offset > last else { continue }
            last = offset
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            let data = try Data(contentsOf: frame.raw.file)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let destinationRow = CVPixelBufferGetBytesPerRow(buffer)
                data.withUnsafeBytes { source in
                    for row in 0..<height {
                        memcpy(
                            base + row * destinationRow, source.baseAddress! + row * frame.raw.bytesPerRow,
                            min(destinationRow, frame.raw.bytesPerRow))
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: offset, preferredTimescale: 6000))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: max(last, end - start), preferredTimescale: 6000))
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? Unavailable(description: "Can't write the movie.")
        }
    }
}
