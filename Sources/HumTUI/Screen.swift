import Foundation

public struct Cell: Equatable, Sendable {
    public var character: Character
    public var style: Style
    /// Columns this cell occupies. Wide glyphs own 2 and leave a `continuation`
    /// cell to their right so the diff never splits them.
    public var width: Int
    public var isContinuation: Bool

    public init(character: Character = " ", style: Style = .default, width: Int = 1, isContinuation: Bool = false) {
        self.character = character
        self.style = style
        self.width = width
        self.isContinuation = isContinuation
    }

    public static let blank = Cell()
}

/// `wcwidth` reports 1 for every wide glyph unless LC_CTYPE is a UTF-8 locale, so
/// a CJK album title would silently shear the grid. Honour the environment's
/// locale when it is already UTF-8, and force UTF-8 ctype when it is not (a bare
/// `LANG` is common over ssh and in CI). Only LC_CTYPE is touched, so number and
/// date formatting elsewhere is unaffected.
private let utf8CtypeLocaleReady: Bool = {
    if let current = setlocale(LC_CTYPE, ""),
       String(cString: current).lowercased().contains("utf-8") {
        return true
    }
    setlocale(LC_CTYPE, "UTF-8")
    return true
}()

/// Columns a character occupies in a terminal, via `wcwidth`. Control characters
/// and anything `wcwidth` rejects are treated as one column so the grid stays sane.
public func displayWidth(_ character: Character) -> Int {
    guard utf8CtypeLocaleReady, let scalar = character.unicodeScalars.first else { return 0 }
    // Grapheme clusters with combining marks: the base scalar decides the width.
    let w = Int(wcwidth(wchar_t(bitPattern: UInt32(scalar.value))))
    if w < 0 { return 1 }
    if w == 0 { return 1 }
    return min(w, 2)
}

public func displayWidth(_ string: String) -> Int {
    string.reduce(0) { $0 + displayWidth($1) }
}

/// A grid of cells plus the previous frame, so `render` can emit only what changed.
///
/// Drawing goes into `back`; `render()` walks it against `front`, emits the
/// minimal cursor-move + SGR + text sequence, then swaps. This is what makes
/// a full-screen 60fps-ish redraw cost a few hundred bytes instead of 80×24
/// styled cells every frame.
public final class Screen {
    public private(set) var columns: Int
    public private(set) var rows: Int

    private var back: [Cell]
    private var front: [Cell]
    private var forceFullRedraw = true

    /// How colours are encoded on the way out. Detected from the environment;
    /// settable for tests.
    public var colorDepth: ColorDepth = .detected

    public init(columns: Int, rows: Int) {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
        let count = self.columns * self.rows
        back = Array(repeating: .blank, count: count)
        front = Array(repeating: .blank, count: count)
    }

    public var bounds: Rect { Rect(x: 0, y: 0, width: columns, height: rows) }

    public func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(newColumns, 1)
        let newRows = max(newRows, 1)
        guard newColumns != columns || newRows != rows else { return }
        columns = newColumns
        rows = newRows
        let count = columns * rows
        back = Array(repeating: .blank, count: count)
        front = Array(repeating: .blank, count: count)
        forceFullRedraw = true
    }

    public func clear(style: Style = .default) {
        let blank = Cell(character: " ", style: style)
        for index in back.indices { back[index] = blank }
    }

    private func index(_ x: Int, _ y: Int) -> Int? {
        guard x >= 0, y >= 0, x < columns, y < rows else { return nil }
        return y * columns + x
    }

    public func put(_ character: Character, x: Int, y: Int, style: Style = .default) {
        guard let index = index(x, y) else { return }
        let width = displayWidth(character)
        back[index] = Cell(character: character, style: style, width: width)
        if width == 2, let next = self.index(x + 1, y) {
            back[next] = Cell(character: " ", style: style, width: 1, isContinuation: true)
        }
    }

    /// Draws `string` clipped to `maxWidth` columns. Returns columns consumed.
    @discardableResult
    public func put(_ string: String, x: Int, y: Int, style: Style = .default, maxWidth: Int? = nil) -> Int {
        let limit = maxWidth ?? (columns - x)
        guard limit > 0 else { return 0 }
        var cursor = x
        var used = 0
        for character in string {
            let width = displayWidth(character)
            if used + width > limit { break }
            put(character, x: cursor, y: y, style: style)
            cursor += width
            used += width
        }
        return used
    }

    /// Truncates with an ellipsis when `string` will not fit in `limit` columns.
    @discardableResult
    public func putTruncated(_ string: String, x: Int, y: Int, style: Style = .default, maxWidth: Int) -> Int {
        guard maxWidth > 0 else { return 0 }
        if displayWidth(string) <= maxWidth {
            return put(string, x: x, y: y, style: style, maxWidth: maxWidth)
        }
        guard maxWidth > 1 else { return put("…", x: x, y: y, style: style, maxWidth: maxWidth) }
        let used = put(string, x: x, y: y, style: style, maxWidth: maxWidth - 1)
        put("…", x: x + used, y: y, style: style)
        return used + 1
    }

    public func fill(_ rect: Rect, style: Style, character: Character = " ") {
        for y in rect.minY..<rect.maxY {
            for x in rect.minX..<rect.maxX {
                put(character, x: x, y: y, style: style)
            }
        }
    }

    /// Emits the escape sequence that turns the previous frame into this one.
    /// Returns an empty string when nothing changed, which lets the caller skip
    /// the write entirely.
    public func render() -> String {
        var output = ""
        output.reserveCapacity(2048)
        var lastStyle: Style?
        var cursorX = -1
        var cursorY = -1

        for y in 0..<rows {
            var x = 0
            while x < columns {
                let index = y * columns + x
                let cell = back[index]

                if cell.isContinuation {
                    x += 1
                    continue
                }
                if !forceFullRedraw && cell == front[index] {
                    x += max(cell.width, 1)
                    continue
                }

                if cursorY != y || cursorX != x {
                    output += "\u{1B}[\(y + 1);\(x + 1)H"
                    cursorX = x
                    cursorY = y
                }
                if lastStyle != cell.style {
                    output += cell.style.sgr(depth: colorDepth)
                    lastStyle = cell.style
                }
                output.append(cell.character)
                cursorX += max(cell.width, 1)
                x += max(cell.width, 1)
            }
        }

        if !output.isEmpty && colorDepth != .none {
            output += "\u{1B}[0m"
        }
        front = back
        forceFullRedraw = false
        return output
    }

    /// The cell currently staged at this position. For tests and for widgets
    /// that need to know what is already there.
    public func cell(x: Int, y: Int) -> Cell {
        guard let index = index(x, y) else { return .blank }
        return back[index]
    }

    /// The current contents as one styled string per row, each self-contained
    /// and reset at the end.
    ///
    /// Unlike `render()` this emits no cursor positioning, so the result can be
    /// written to a file, `cat`-ed back, or parsed — which is what makes a frame
    /// shareable as evidence rather than as a colourless paste.
    public func styledLines(depth: ColorDepth? = nil) -> [String] {
        let depth = depth ?? colorDepth
        var lines: [String] = []
        for y in 0..<rows {
            var line = ""
            var lastStyle: Style?
            var x = 0
            while x < columns {
                let cell = back[y * columns + x]
                if cell.isContinuation {
                    x += 1
                    continue
                }
                if lastStyle != cell.style {
                    line += cell.style.sgr(depth: depth)
                    lastStyle = cell.style
                }
                line.append(cell.character)
                x += max(cell.width, 1)
            }
            if depth != .none { line += "\u{1B}[0m" }
            lines.append(line)
        }
        return lines
    }

    /// Forces the next `render()` to repaint every cell — needed after anything
    /// else writes to the terminal (a resize, a suspend/resume, the auth prompt).
    public func invalidate() {
        forceFullRedraw = true
    }
}

public struct Rect: Equatable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = max(width, 0)
        self.height = max(height, 0)
    }

    public var minX: Int { x }
    public var minY: Int { y }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func inset(by amount: Int) -> Rect {
        Rect(x: x + amount, y: y + amount, width: width - amount * 2, height: height - amount * 2)
    }

    /// Splits off `amount` rows from the top, returning (taken, remainder).
    public func splitTop(_ amount: Int) -> (Rect, Rect) {
        let taken = min(amount, height)
        return (
            Rect(x: x, y: y, width: width, height: taken),
            Rect(x: x, y: y + taken, width: width, height: height - taken)
        )
    }

    public func splitBottom(_ amount: Int) -> (Rect, Rect) {
        let taken = min(amount, height)
        return (
            Rect(x: x, y: y + height - taken, width: width, height: taken),
            Rect(x: x, y: y, width: width, height: height - taken)
        )
    }

    public func splitLeft(_ amount: Int) -> (Rect, Rect) {
        let taken = min(amount, width)
        return (
            Rect(x: x, y: y, width: taken, height: height),
            Rect(x: x + taken, y: y, width: width - taken, height: height)
        )
    }

    /// Splits off `amount` columns from the left and drops a one-column gap
    /// between the two halves.
    ///
    /// Panels each draw their own border, so packing them flush puts two lines
    /// at every seam and four corners wherever they meet. The gap is what makes
    /// them read as separate cards.
    public func splitLeft(_ amount: Int, gap: Int) -> (Rect, Rect) {
        let (left, rest) = splitLeft(amount)
        guard rest.width > gap else { return (left, rest) }
        return (left, Rect(x: rest.x + gap, y: rest.y, width: rest.width - gap, height: rest.height))
    }

    /// `splitTop`, leaving a `gap`-row gutter below the taken rows.
    public func splitTop(_ amount: Int, gap: Int) -> (Rect, Rect) {
        let (top, rest) = splitTop(amount)
        guard rest.height > gap else { return (top, rest) }
        return (top, Rect(x: rest.x, y: rest.y + gap, width: rest.width, height: rest.height - gap))
    }

    /// `splitBottom`, leaving a `gap`-row gutter above the taken rows.
    public func splitBottom(_ amount: Int, gap: Int) -> (Rect, Rect) {
        let (bottom, rest) = splitBottom(amount)
        guard rest.height > gap else { return (bottom, rest) }
        return (bottom, Rect(x: rest.x, y: rest.y, width: rest.width, height: rest.height - gap))
    }
}
