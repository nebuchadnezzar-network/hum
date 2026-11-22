import Darwin
import Foundation

// MARK: - Async-signal-safe restore
//
// A signal handler may run while the interrupted thread holds the malloc lock, so
// it must not allocate, retain/release, or call into Swift runtime machinery. All
// it may touch is this preallocated storage plus `tcsetattr` and `write`, both of
// which are async-signal-safe. Everything here is allocated eagerly by
// `Terminal.installRestoreHandlers()` so no lazy global initialiser can run
// inside the handler.

private let savedTerminalAttributes = UnsafeMutablePointer<termios>.allocate(capacity: 1)
private let hasSavedTerminalAttributes = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

/// `SGR reset`, `show cursor`, `leave alternate screen`.
private let restoreSequence = "\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l"
private let restoreBytes = UnsafeMutablePointer<CChar>.allocate(capacity: restoreSequence.utf8.count)
private let restoreByteCount = restoreSequence.utf8.count

private func signalSafeRestore() {
    if hasSavedTerminalAttributes.pointee != 0 {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, savedTerminalAttributes)
        hasSavedTerminalAttributes.pointee = 0
    }
    _ = write(STDOUT_FILENO, restoreBytes, restoreByteCount)
}

/// Owns the process's terminal state: raw mode, the alternate screen, and resize
/// notifications. Exactly one of these should exist, and it must be torn down on
/// every exit path or the user is left with a dark, echo-less shell.
public final class Terminal {
    public struct Size: Equatable, Sendable {
        public var columns: Int
        public var rows: Int
        public init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
        }
    }

    private var original: termios?
    private var resizeSource: DispatchSourceSignal?

    public private(set) var isRaw = false

    public init() {}

    public static var isAttachedToTTY: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    /// Arranges for the terminal to be put back on fatal signals and at exit.
    ///
    /// Call once, before entering raw mode. SIGINT is deliberately absent: raw
    /// mode clears ISIG so Ctrl-C arrives as a keystroke instead.
    public static func installRestoreHandlers() {
        hasSavedTerminalAttributes.pointee = 0
        restoreSequence.withCString { source in
            restoreBytes.update(from: source, count: restoreByteCount)
        }

        for signalNumber in [SIGTERM, SIGHUP, SIGQUIT, SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGPIPE] {
            signal(signalNumber) { number in
                signalSafeRestore()
                // Re-raise with the default disposition so the exit status is honest.
                signal(number, SIG_DFL)
                raise(number)
            }
        }
        // atexit runs on a normal thread, so the full restore is fine here.
        atexit { signalSafeRestore() }
    }

    public var size: Size {
        var ws = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 else {
            return Size(columns: 80, rows: 24)
        }
        return Size(columns: Int(ws.ws_col), rows: Int(ws.ws_row))
    }

    // MARK: - Mode

    public func enterRawMode() {
        guard !isRaw else { return }
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        original = raw
        // Hand a copy to the signal-safe storage so a crash can undo this.
        savedTerminalAttributes.pointee = raw
        hasSavedTerminalAttributes.pointee = 1

        // cfmakeraw, spelled out: no echo, no line buffering, no signal generation
        // from Ctrl-C (we want it as a key), no CR/LF translation.
        raw.c_iflag &= ~UInt(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
        raw.c_oflag &= ~UInt(OPOST)
        raw.c_cflag |= UInt(CS8)
        raw.c_lflag &= ~UInt(ECHO | ICANON | IEXTEN | ISIG)

        // A blocking read of at least one byte: the input thread parks here instead
        // of spinning, which is what keeps idle CPU at zero.
        raw.c_cc.16 = 1  // VMIN
        raw.c_cc.17 = 0  // VTIME

        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        isRaw = true
    }

    public func exitRawMode() {
        guard isRaw, var original else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        hasSavedTerminalAttributes.pointee = 0
        isRaw = false
    }

    // MARK: - Screen

    public func enterAlternateScreen() {
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J\u{1B}[H")
    }

    public func leaveAlternateScreen() {
        write("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
    }

    /// Sets the window title, leaving the icon and tab name alone.
    ///
    /// `OSC 0` sets both, and Terminal.app's own title format already includes
    /// the active process name — so setting both to "hum" produced three
    /// identical sources joined by Terminal's separator:
    ///
    ///     hum — hum — hum
    ///
    /// `OSC 2` is the window title only, which leaves one "hum" from the
    /// process name and room for something worth reading beside it.
    public func setWindowTitle(_ title: String) {
        write("\u{1B}]2;\(title)\u{0007}")
    }

    /// Hands the title back to the terminal's own default.
    public func resetWindowTitle() {
        write("\u{1B}]2;\u{0007}")
    }

    public func write(_ string: String) {
        guard !string.isEmpty else { return }
        let bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer in
                Darwin.write(STDOUT_FILENO, buffer.baseAddress! + offset, bytes.count - offset)
            }
            if written <= 0 { break }
            offset += written
        }
    }

    // MARK: - Resize

    /// Starts delivering SIGWINCH to `handler` on a background queue. The default
    /// disposition has to be ignored first or the process dies before the source runs.
    public func onResize(_ handler: @escaping (Size) -> Void) {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            handler(self.size)
        }
        source.resume()
        resizeSource = source
    }

    /// Restores the terminal. Safe to call more than once; `atexit`-style paths do.
    public func restore() {
        resetWindowTitle()
        leaveAlternateScreen()
        exitRawMode()
    }
}
