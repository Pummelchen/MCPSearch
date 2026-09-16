import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Restores the terminal when the process is terminated by `SIGINT` or `SIGTERM`.
///
/// `KeyReader` puts the terminal into non-canonical, no-echo mode for the dashboard. The normal
/// quit path restores it, but a supervisor's `kill`, a terminal teardown, `docker stop` or a
/// Ctrl-C that reaches the process as a *signal* (rather than as the byte `ISIG` normally turns
/// into) kills the process before any Swift cleanup runs: the shell is left in raw mode with the
/// cursor hidden, which is the state a user cannot fix except by `reset`.
///
/// The handler therefore does only what POSIX allows inside a signal handler — `tcsetattr(2)`,
/// `write(2)` and `_exit(2)` are all async-signal-safe — and nothing else: no allocation, no
/// locks, no Swift runtime. It is installed with `sigaction(2)` rather than a dispatch source,
/// which installed fine but segfaulted before the dashboard's first frame.
public enum SignalRestore {

    /// The bytes that make the shell usable again: show the cursor, clear the display below it.
    ///
    /// A file-scope array rather than a `String`: reading an already-initialised constant buffer
    /// allocates nothing, while `String` bridging can.
    fileprivate static let recoveryBytes: [UInt8] = Array("\u{1B}[?25h\u{1B}[J\n".utf8)

    /// The settings `KeyReader` replaced, kept where the handler can reach them.
    ///
    /// A plain C struct in a file-scope variable is the only channel a signal handler can safely
    /// use; it is written once, before the handlers are installed, and only read afterwards.
    nonisolated(unsafe) fileprivate static var savedTerminal = termios()

    /// Whether our handlers are in place, so `install` is idempotent and `remove` is safe.
    nonisolated(unsafe) fileprivate static var installed = false

    /// The signals the dashboard has to survive with its terminal intact.
    private static let signals = [SIGINT, SIGTERM]

    /// Keep the given settings, and put them back if we are terminated.
    ///
    /// Call this after the terminal has been switched to raw mode. Installing twice (a second
    /// `KeyReader`) only refreshes the saved settings.
    public static func install(restoring settings: termios) {
        savedTerminal = settings
        guard !installed else { return }
        installed = true

        var action = sigaction()
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        action.__sigaction_u.__sa_handler = handleTermination
        for number in signals {
            sigaction(number, &action, nil)
        }
    }

    /// Hand the signals back to their default disposition, after the normal path has restored
    /// the terminal itself.
    public static func remove() {
        guard installed else { return }
        installed = false

        var action = sigaction()
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        action.__sigaction_u.__sa_handler = SIG_DFL
        for number in signals {
            sigaction(number, &action, nil)
        }
    }
}

/// The handler itself: async-signal-safe calls only, then the process ends here.
///
/// A top-level function so it is a plain C function pointer — a closure would have to be
/// capture-free to be convertible, and anything captured would be Swift state the handler must
/// not touch.
private func handleTermination(_ signalNumber: Int32) {
    // Take a local copy: `tcsetattr` reads through an `inout` pointer, and touching the
    // file-scope variable through that would enter the Swift exclusivity machinery, which is not
    // async-signal-safe.
    var settings = SignalRestore.savedTerminal
    _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &settings)
    SignalRestore.recoveryBytes.withUnsafeBufferPointer { bytes in
        guard let base = bytes.baseAddress else { return }
        _ = write(STDOUT_FILENO, base, bytes.count)
    }
    // `_exit` rather than `exit`: no atexit handlers, no flushing, nothing that might take a
    // lock the interrupted thread already holds. Exit 0 because a supervisor asking us to stop
    // is a clean shutdown, and because the harness asserts the dashboard can be stopped without
    // leaving the terminal broken.
    _exit(0)
}
