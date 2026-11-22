import Foundation

/// The glyphs a panel frame is drawn from.
///
/// Sharp by default. The rounded set (`╭ ╮ ╰ ╯`, U+256D–U+2570) was the default
/// and it is the wrong choice for a terminal: those four are arcs, not right
/// angles, and in the fonts a terminal actually ships with — Menlo, SF Mono —
/// the arc's stroke does not land where the adjacent `─` and `│` land. The
/// corner reads as slightly loose, or slightly off-square, because it is. The
/// sharp set is the canonical box-drawing corner and joins exactly.
///
/// `HUM_BORDERS=rounded` puts them back for anyone whose font draws them well.
public struct BorderStyle: Sendable {
    public let topLeft: Character
    public let topRight: Character
    public let bottomLeft: Character
    public let bottomRight: Character
    public let horizontal: Character
    public let vertical: Character
    /// Where a shared rule meets the top and bottom edges.
    public let topTee: Character
    public let bottomTee: Character

    public static let sharp = BorderStyle(
        topLeft: "┌", topRight: "┐", bottomLeft: "└", bottomRight: "┘",
        horizontal: "─", vertical: "│", topTee: "┬", bottomTee: "┴"
    )

    public static let rounded = BorderStyle(
        topLeft: "╭", topRight: "╮", bottomLeft: "╰", bottomRight: "╯",
        horizontal: "─", vertical: "│", topTee: "┬", bottomTee: "┴"
    )

    public static let current: BorderStyle = {
        ProcessInfo.processInfo.environment["HUM_BORDERS"] == "rounded" ? .rounded : .sharp
    }()
}

// MARK: - Panel

/// Rounded box with an optional title, matching the boxed icon in the branding file.
public struct Panel {
    public var title: String?
    public var isFocused: Bool
    public var style: Style
    public var titleStyle: Style

    public init(
        title: String? = nil,
        isFocused: Bool = false,
        style: Style = Style(fg: Palette.border, bg: Palette.ink),
        titleStyle: Style = Style(fg: Palette.mute, bg: Palette.ink)
    ) {
        self.title = title
        self.isFocused = isFocused
        self.style = style
        self.titleStyle = titleStyle
    }

    /// Draws the frame and returns the content rect inside it.
    @discardableResult
    public func draw(in rect: Rect, on screen: Screen) -> Rect {
        guard rect.width >= 2, rect.height >= 2 else { return rect }

        let frame = isFocused ? style.fg(Palette.amber) : style
        let label = isFocused ? titleStyle.fg(Palette.amber).with(.bold) : titleStyle

        let top = rect.minY, bottom = rect.maxY - 1
        let left = rect.minX, right = rect.maxX - 1

        let border = BorderStyle.current
        screen.put(border.topLeft, x: left, y: top, style: frame)
        screen.put(border.topRight, x: right, y: top, style: frame)
        screen.put(border.bottomLeft, x: left, y: bottom, style: frame)
        screen.put(border.bottomRight, x: right, y: bottom, style: frame)

        for x in (left + 1)..<right {
            screen.put(border.horizontal, x: x, y: top, style: frame)
            screen.put(border.horizontal, x: x, y: bottom, style: frame)
        }
        for y in (top + 1)..<bottom {
            screen.put(border.vertical, x: left, y: y, style: frame)
            screen.put(border.vertical, x: right, y: y, style: frame)
        }

        if let title, !title.isEmpty, rect.width > 6 {
            let available = rect.width - 6
            screen.put(" ", x: left + 2, y: top, style: frame)
            let used = screen.putTruncated(title, x: left + 3, y: top, style: label, maxWidth: available)
            screen.put(" ", x: left + 3 + used, y: top, style: frame)
        }

        return rect.inset(by: 1)
    }
}

// MARK: - List

/// Scrolling single-selection list. Owns its scroll offset so the caller only
/// tracks the selected index.
public struct ListView {
    public struct Row {
        public var text: String
        public var detail: String?
        public var style: Style?
        public var accent: Character?

        public init(text: String, detail: String? = nil, style: Style? = nil, accent: Character? = nil) {
            self.text = text
            self.detail = detail
            self.style = style
            self.accent = accent
        }
    }

    public var rows: [Row]
    public var selected: Int
    public var isFocused: Bool
    /// Scroll offset, updated in place by `draw` so the selection stays visible.
    public var offset: Int

    public init(rows: [Row], selected: Int = 0, isFocused: Bool = false, offset: Int = 0) {
        self.rows = rows
        self.selected = selected
        self.isFocused = isFocused
        self.offset = offset
    }

    /// Clamps `offset` so `selected` is on screen. Call before `draw` and persist
    /// the result; `draw` itself does not mutate.
    public mutating func scrollToSelection(viewportHeight: Int) {
        guard viewportHeight > 0 else { return }
        let maxOffset = max(0, rows.count - viewportHeight)
        if selected < offset {
            offset = selected
        } else if selected >= offset + viewportHeight {
            offset = selected - viewportHeight + 1
        }
        offset = min(max(0, offset), maxOffset)
    }

    public func draw(in rect: Rect, on screen: Screen) {
        guard !rect.isEmpty else { return }
        screen.fill(rect, style: Style(fg: Palette.fog, bg: Palette.ink))

        if rows.isEmpty {
            screen.putTruncated(
                "nothing here",
                x: rect.minX + 1,
                y: rect.minY,
                style: Style(fg: Palette.mute, bg: Palette.ink).with(.italic),
                maxWidth: rect.width - 2
            )
            return
        }

        // A visible scrollbar owns the last column, so row content has to stop
        // one short of it — otherwise it clips the final character of the detail
        // column and a duration reads as "3:4".
        let scrollbarColumns = hasScrollbar(in: rect) ? 1 : 0
        let contentMaxX = rect.maxX - scrollbarColumns

        for line in 0..<rect.height {
            let index = offset + line
            guard index < rows.count else { break }
            let row = rows[index]
            let y = rect.minY + line
            let isSelected = index == selected

            var style = row.style ?? Style(fg: Palette.fog, bg: Palette.ink)
            if isSelected {
                // Focused selection gets the amber bar; unfocused keeps a dimmer
                // marker so you can still see where you were in the other pane.
                style = isFocused
                    ? Style(fg: Palette.ink, bg: Palette.amber).with(.bold)
                    : Style(fg: Palette.fog, bg: Palette.panel)
            }

            screen.fill(Rect(x: rect.minX, y: y, width: rect.width, height: 1), style: style)

            var x = rect.minX
            let marker: Character = isSelected ? "▸" : (row.accent ?? " ")
            screen.put(marker, x: x, y: y, style: style)
            x += 2

            let detailWidth = row.detail.map { displayWidth($0) + 2 } ?? 0
            let textWidth = max(0, contentMaxX - x - detailWidth)
            screen.putTruncated(row.text, x: x, y: y, style: style, maxWidth: textWidth)

            if let detail = row.detail, detailWidth > 0 {
                let detailStyle = isSelected && isFocused
                    ? style
                    : style.fg(Palette.mute)
                let width = displayWidth(detail)
                screen.putTruncated(detail, x: contentMaxX - width, y: y, style: detailStyle, maxWidth: width)
            }
        }

        drawScrollbar(in: rect, on: screen)
    }

    private func hasScrollbar(in rect: Rect) -> Bool {
        rows.count > rect.height && rect.height > 2
    }

    private func drawScrollbar(in rect: Rect, on screen: Screen) {
        guard hasScrollbar(in: rect) else { return }
        let trackHeight = rect.height
        let thumbHeight = max(1, trackHeight * trackHeight / rows.count)
        let maxOffset = max(1, rows.count - trackHeight)
        let thumbTop = (trackHeight - thumbHeight) * offset / maxOffset
        let x = rect.maxX - 1
        for line in 0..<trackHeight {
            let inThumb = line >= thumbTop && line < thumbTop + thumbHeight
            screen.put(
                inThumb ? "▐" : "▕",
                x: x,
                y: rect.minY + line,
                style: Style(fg: inThumb ? Palette.amberDark : Palette.panel, bg: Palette.ink)
            )
        }
    }
}

// MARK: - Progress

/// The status-line scrubber: `━━━━━` filled in amber, remainder in mute.
public func drawProgressBar(
    in rect: Rect,
    on screen: Screen,
    fraction: Double,
    background: Color = Palette.ink
) {
    guard rect.width > 0 else { return }
    let fraction = min(max(fraction, 0), 1)
    let filled = Int((Double(rect.width) * fraction).rounded())
    for x in 0..<rect.width {
        let isFilled = x < filled
        screen.put(
            "━",
            x: rect.minX + x,
            y: rect.minY,
            style: Style(fg: isFilled ? Palette.amber : Palette.panel.mix(Palette.mute, 0.3), bg: background)
        )
    }
    // A brighter head on the boundary reads as a playhead rather than a fill.
    if filled > 0 && filled <= rect.width {
        screen.put(
            "●",
            x: rect.minX + min(filled - 1, rect.width - 1),
            y: rect.minY,
            style: Style(fg: Palette.amber, bg: background).with(.bold)
        )
    }
}

// MARK: - Branding

/// The splash banner from `branding/text-icons.txt`, drawn centred.
public let splashBanner: [String] = [
    #"\       _"#,
    #" \     | |__  _   _ _ __ ___"#,
    #"  > )))| '_ \| | | | '_ ` _ \"#,
    #" /     | | | | |_| | | | | | |"#,
    #"/      |_| |_|\__,_|_| |_| |_|"#,
]

public func drawSplash(in rect: Rect, on screen: Screen, subtitle: String? = nil) {
    let bannerWidth = splashBanner.map { displayWidth($0) }.max() ?? 0
    let totalHeight = splashBanner.count + (subtitle == nil ? 0 : 2)
    let startY = rect.minY + max(0, (rect.height - totalHeight) / 2)
    let startX = rect.minX + max(0, (rect.width - bannerWidth) / 2)

    for (line, text) in splashBanner.enumerated() {
        let y = startY + line
        guard y < rect.maxY else { break }
        // The ")))" wave in the middle of the banner is the mark — keep it amber,
        // and let the wordmark itself sit in fog.
        var x = startX
        for character in text {
            let isWave = character == ")" || character == ">"
            screen.put(
                character,
                x: x,
                y: y,
                style: Style(fg: isWave ? Palette.amber : Palette.fog, bg: Palette.ink)
            )
            x += displayWidth(character)
        }
    }

    if let subtitle {
        let y = startY + splashBanner.count + 1
        if y < rect.maxY {
            let x = rect.minX + max(0, (rect.width - displayWidth(subtitle)) / 2)
            screen.putTruncated(subtitle, x: x, y: y, style: Style(fg: Palette.mute, bg: Palette.ink), maxWidth: rect.width)
        }
    }
}

/// `2:14` / `1:05:29` depending on length. No leading zero on the leading unit —
/// a track is "3:47", not "03:47".
public func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}
