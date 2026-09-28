import Foundation

/// Command output read into lines: SGR colours and weights kept as style runs,
/// every other escape sequence dropped, and a line rewritten by carriage
/// returns (a progress bar) kept as it finally read.
public enum ANSIText {
    /// The output as lines, numbered from 1.
    public static func lines(of output: String) -> [SourceLine] {
        var parser = Parser()
        for scalar in output.unicodeScalars {
            parser.consume(scalar)
        }
        parser.endLine(final: true)
        return parser.lines
    }

    /// The output with every escape sequence removed.
    public static func plainText(of output: String) -> String {
        guard output.contains("\u{1B}") || output.contains("\r") else { return output }
        return lines(of: output).map(\.text).joined(separator: "\n")
    }
}

private struct Parser {
    struct Style: Equatable {
        var foreground: SourceStyleRun.Color?
        var background: SourceStyleRun.Color?
        var isBold = false
        var isDim = false
        var isItalic = false
        var isUnderlined = false

        var isPlain: Bool { self == Style() }
    }

    enum State {
        case text
        /// After ESC.
        case escape
        /// Inside `ESC [ …`, collecting parameters until a final byte.
        case csi(String)
        /// Inside `ESC ] …`, until BEL or `ESC \`.
        case osc(sawEscape: Bool)
    }

    var lines: [SourceLine] = []
    var text = ""
    var length = 0
    var runs: [SourceStyleRun] = []
    var runStart = 0
    var style = Style()
    var state = State.text
    /// A carriage return was read; the next character starts the line over,
    /// unless it is the newline of a `\r\n`.
    var pendingReturn = false

    mutating func consume(_ scalar: Unicode.Scalar) {
        switch state {
        case .text:
            consumeText(scalar)
        case .escape:
            switch scalar {
            case "[": state = .csi("")
            case "]": state = .osc(sawEscape: false)
            default: state = .text  // A two-byte sequence (`ESC =`, `ESC 7`): dropped.
            }
        case .csi(let parameters):
            if (0x40...0x7E).contains(scalar.value) {
                if scalar == "m" { apply(parameters) }
                state = .text
            } else {
                state = .csi(parameters + String(scalar))
            }
        case .osc(let sawEscape):
            if scalar == "\u{07}" || (sawEscape && scalar == "\\") {
                state = .text
            } else {
                state = .osc(sawEscape: scalar == "\u{1B}")
            }
        }
    }

    private mutating func consumeText(_ scalar: Unicode.Scalar) {
        switch scalar {
        case "\u{1B}":
            state = .escape
        case "\n":
            pendingReturn = false
            endLine(final: false)
        case "\r":
            pendingReturn = true
        default:
            if pendingReturn {
                pendingReturn = false
                text = ""
                length = 0
                runs = []
                runStart = 0
            }
            guard scalar.value >= 0x20 || scalar == "\t" else { return }
            text.unicodeScalars.append(scalar)
            length += scalar.utf16.count
        }
    }

    mutating func endLine(final: Bool) {
        closeRun()
        if final, text.isEmpty, !lines.isEmpty { return }
        lines.append(SourceLine(text: text, number: lines.count + 1, styles: runs))
        text = ""
        length = 0
        runs = []
        runStart = 0
    }

    private mutating func closeRun() {
        if !style.isPlain, length > runStart {
            runs.append(
                SourceStyleRun(
                    range: runStart..<length, foreground: style.foreground, background: style.background,
                    isBold: style.isBold, isDim: style.isDim, isItalic: style.isItalic,
                    isUnderlined: style.isUnderlined))
        }
        runStart = length
    }

    /// Select Graphic Rendition: `ESC [ … m`.
    private mutating func apply(_ parameters: String) {
        closeRun()
        var codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        if codes.isEmpty { codes = [0] }
        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0: style = Style()
            case 1: style.isBold = true
            case 2: style.isDim = true
            case 3: style.isItalic = true
            case 4: style.isUnderlined = true
            case 22:
                style.isBold = false
                style.isDim = false
            case 23: style.isItalic = false
            case 24: style.isUnderlined = false
            case 30...37: style.foreground = Self.basic[code - 30]
            case 39: style.foreground = nil
            case 40...47: style.background = Self.basic[code - 40]
            case 49: style.background = nil
            case 90...97: style.foreground = Self.bright[code - 90]
            case 100...107: style.background = Self.bright[code - 100]
            case 38, 48:
                let (color, consumed) = Self.extended(Array(codes[(i + 1)...]))
                if code == 38 { style.foreground = color } else { style.background = color }
                i += consumed
            default: break
            }
            i += 1
        }
    }

    private static let basic: [SourceStyleRun.Color] = [.black, .red, .green, .yellow, .blue, .magenta, .cyan, .white]
    private static let bright: [SourceStyleRun.Color] = [
        .brightBlack, .brightRed, .brightGreen, .brightYellow, .brightBlue, .brightMagenta, .brightCyan, .brightWhite,
    ]

    /// `5;n` (256 colours) or `2;r;g;b`, and how many parameters it used.
    private static func extended(_ rest: [Int]) -> (SourceStyleRun.Color?, Int) {
        guard let mode = rest.first else { return (nil, 0) }
        if mode == 5, rest.count >= 2 { return (palette(rest[1]), 2) }
        if mode == 2, rest.count >= 4 {
            return (.rgb(UInt8(clamping: rest[1]), UInt8(clamping: rest[2]), UInt8(clamping: rest[3])), 4)
        }
        return (nil, 1)
    }

    /// The xterm 256-colour palette: 16 named, a 6×6×6 cube, 24 greys.
    private static func palette(_ n: Int) -> SourceStyleRun.Color? {
        switch n {
        case 0..<8: return basic[n]
        case 8..<16: return bright[n - 8]
        case 16..<232:
            let i = n - 16
            let level: (Int) -> UInt8 = { $0 == 0 ? 0 : UInt8(55 + $0 * 40) }
            return .rgb(level(i / 36), level((i / 6) % 6), level(i % 6))
        case 232..<256:
            let grey = UInt8(8 + (n - 232) * 10)
            return .rgb(grey, grey, grey)
        default: return nil
        }
    }
}
