import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Low-level terminal control for a full-screen dashboard.
///
/// Everything here is deliberately dependency-free ANSI/VT100 handling: the display is
/// rewritten in place on each refresh, which is what makes it a live monitor rather than
/// a stream of appended lines.
public enum Terminal {

    // MARK: - Capabilities

    /// Whether stdout is a terminal. Without this check, redirecting output to a file or
    /// a pipe would fill it with cursor-movement escapes instead of readable text.
    public static var isInteractive: Bool {
        isatty(STDOUT_FILENO) == 1
    }

    /// Terminal size in columns and rows.
    ///
    /// Falls back to 120x40 when the size cannot be determined (for example when not
    /// attached to a TTY), so the layout still renders sensibly.
    public static var size: (columns: Int, rows: Int) {
        var window = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &window) == 0, window.ws_col > 0 {
            return (Int(window.ws_col), Int(window.ws_row))
        }
        return (120, 40)
    }

    // MARK: - Escape sequences

    public static let clearScreen = "\u{1B}[2J"
    public static let clearToEndOfLine = "\u{1B}[K"
    public static let clearToEndOfScreen = "\u{1B}[J"
    public static let hideCursor = "\u{1B}[?25l"
    public static let showCursor = "\u{1B}[?25h"

    /// Move the cursor to a 1-based row and column.
    public static func move(row: Int, column: Int) -> String {
        "\u{1B}[\(row);\(column)H"
    }

    public static func home() -> String { move(row: 1, column: 1) }

    // MARK: - Styling

    public enum Colour: String {
        case red = "31"
        case green = "32"
        case yellow = "33"
        case blue = "34"
        case magenta = "35"
        case cyan = "36"
        case white = "37"
        case grey = "90"
        case brightRed = "91"
        case brightGreen = "92"
        case brightYellow = "93"
        case brightCyan = "96"
        case brightWhite = "97"
    }

    /// Wrap text in a colour, or return it unchanged when colour is disabled.
    public static func colour(_ text: String, _ colour: Colour, enabled: Bool) -> String {
        guard enabled else { return text }
        return "\u{1B}[\(colour.rawValue)m\(text)\u{1B}[0m"
    }

    public static func bold(_ text: String, enabled: Bool = true) -> String {
        guard enabled else { return text }
        return "\u{1B}[1m\(text)\u{1B}[0m"
    }

    // MARK: - Width-safe text

    /// Pad to a width, truncating when necessary. Keeps columns aligned even when a
    /// provider returns a long error message.
    public static func pad(_ text: String, to width: Int, alignment: Alignment = .left) -> String {
        let visible = displayWidth(text)
        if visible > width {
            return truncate(text, to: width)
        }
        let padding = String(repeating: " ", count: width - visible)
        switch alignment {
        case .left: return text + padding
        case .right: return padding + text
        }
    }

    public enum Alignment { case left, right }

    public static func truncate(_ text: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        if displayWidth(text) <= width { return text }
        guard width > 1 else { return String(text.prefix(width)) }
        // Walk backwards to the last character that fits, then add an ellipsis.
        var result = ""
        var used = 0
        for character in text {
            let cost = character.unicodeScalars.reduce(0) { $0 + scalarWidth($1) }
            if used + cost > width - 1 { break }
            result.append(character)
            used += cost
        }
        return result + "…"
    }

    /// Approximate display width.
    ///
    /// Counts ANSI escape sequences as zero width, which matters because styled text is
    /// padded after colouring. Wide CJK and emoji characters count as two columns.
    public static func displayWidth(_ text: String) -> Int {
        var width = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\u{1B}", text.index(after: index) < text.endIndex,
                text[text.index(after: index)] == "["
            {
                // Skip to the terminating letter of the escape sequence.
                var cursor = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                while cursor < text.endIndex, !text[cursor].isLetter {
                    cursor = text.index(after: cursor)
                }
                index = cursor < text.endIndex ? text.index(after: cursor) : text.endIndex
                continue
            }
            width += character.unicodeScalars.reduce(0) { $0 + scalarWidth($1) }
            index = text.index(after: index)
        }
        return width
    }

    private static func scalarWidth(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0..<0x20, 0x7F:
            return 0
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
            0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60,
            0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF:
            return 2
        default:
            return 1
        }
    }
}

// MARK: - Raw keyboard input

/// Reads single key presses without waiting for Enter.
///
/// The terminal is switched into non-canonical mode with echo disabled, and `raw` is
/// dropped when the process exits so a crash cannot leave the user's shell unusable.
public final class KeyReader: @unchecked Sendable {
    private var original = termios()

    public init?() {
        guard isatty(STDIN_FILENO) == 1 else { return nil }
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }

        var raw = original
        // Non-canonical, no echo: we want each key as it is pressed, invisibly. `ISIG` is cleared
        // as well, so Ctrl-C arrives as the byte `\u{03}` and the dashboard's own quit branch
        // handles it. With `ISIG` set the terminal raised `SIGINT` instead, the process died on
        // the spot, and that branch was unreachable in a real terminal (ledger B10).
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        // Do not wait for a full buffer or translate carriage returns.
        raw.c_cc.0 = 0  // VMIN: return immediately
        raw.c_cc.1 = 0  // VTIME: no inter-byte timeout
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return nil }
    }

    /// Restore the original terminal settings.
    public func restore() {
        var restore = original
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
    }

    /// Return one pending byte, or nil when nothing has been typed.
    public func readByte() -> UInt8? {
        var byte: UInt8 = 0
        let count = read(STDIN_FILENO, &byte, 1)
        return count == 1 ? byte : nil
    }

    deinit {
        restore()
    }
}
