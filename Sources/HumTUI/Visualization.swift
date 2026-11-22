import Dispatch
import Foundation

/// Which visualisation the top panel is showing.
///
/// Visibility is deliberately *not* a case here: switching style and hiding the
/// panel are different intents and get different keys, so cycling styles never
/// takes you through "off" to get back.
public enum Visualization: CaseIterable, Sendable {
    case bars, scope

    public var title: String {
        switch self {
        case .bars: return "spectrum"
        case .scope: return "waveform"
        }
    }

    public var next: Visualization {
        let all = Visualization.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }
}

private let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

// MARK: - Spectrum bars

/// Spectrum analyser drawn with block glyphs.
///
/// Bars are a couple of columns wide with a gap between them, because one bar per
/// column with no gaps draws as a solid wall rather than a spectrum. Holds its own
/// peak-decay state, so it must be stored across frames rather than rebuilt.
public struct SpectrumMeter {
    /// Columns per bar, and columns of background between them.
    public var barWidth: Int
    public var gap: Int
    public var showPeaks: Bool

    /// Peak-hold level per bar, 0...1.
    private var peaks: [Double] = []
    private var lastDraw: UInt64 = 0

    public init(barWidth: Int = 2, gap: Int = 1, showPeaks: Bool = true) {
        self.barWidth = max(1, barWidth)
        self.gap = max(0, gap)
        self.showPeaks = showPeaks
    }

    /// How many bars fit in `width` columns — ask the analyser for exactly this
    /// many so no resampling happens twice.
    public func barCount(forWidth width: Int) -> Int {
        guard width > 0 else { return 0 }
        return max(1, (width + gap) / (barWidth + gap))
    }

    /// Caps fall about a third of the display per second. Expressed per *second*
    /// rather than per frame on purpose: a per-frame rate makes the caps fall
    /// twice as fast the moment the render loop speeds up. Snaps to zero at the
    /// bottom so a silent display stops changing and the renderer can go quiet.
    private static let peakReleasePerSecond = 0.36

    public mutating func draw(
        in rect: Rect,
        on screen: Screen,
        magnitudes: [Double],
        background: Color = Palette.ink
    ) {
        guard !rect.isEmpty, !magnitudes.isEmpty else { return }

        if peaks.count != magnitudes.count {
            peaks = magnitudes
        }

        let now = DispatchTime.now().uptimeNanoseconds
        // Clamp the first frame and any long stall (a resize, a suspend) so the
        // caps do not jump straight to the floor.
        let elapsed = lastDraw == 0 ? 1.0 / 60 : min(0.25, Double(now &- lastDraw) / 1_000_000_000)
        lastDraw = now
        let release = Self.peakReleasePerSecond * elapsed

        let height = rect.height
        for (index, magnitude) in magnitudes.enumerated() {
            let x0 = rect.minX + index * (barWidth + gap)
            guard x0 < rect.maxX else { break }
            let columns = min(barWidth, rect.maxX - x0)

            let magnitude = min(max(magnitude, 0), 1)
            let released = max(peaks[index] - release, 0)
            let peak = max(magnitude, released)
            peaks[index] = peak < 0.01 ? 0 : peak

            let level = Double(height) * magnitude
            let fullRows = Int(level)
            let remainder = level - Double(fullRows)

            // Peak cap only when it has pulled clear of the bar, otherwise it
            // would just overwrite the bar's own top.
            let peakRow = min(height - 1, Int(Double(height) * peaks[index]))
            let showCap = showPeaks && peaks[index] > 0.02 && peakRow > fullRows

            for row in 0..<height {
                let y = rect.maxY - 1 - row
                // Hotter towards the top of the bar: amber at the peak,
                // amber-dark at the base.
                let heat = height > 1 ? Double(row) / Double(height - 1) : 1
                let barStyle = Style(fg: Palette.amberDark.mix(Palette.amber, heat), bg: background)

                let glyph: Character
                var style = barStyle
                if row < fullRows {
                    glyph = "█"
                } else if row == fullRows && remainder > 0.08 {
                    glyph = blocks[min(blocks.count - 1, Int(remainder * Double(blocks.count)))]
                } else if showCap && row == peakRow {
                    // A thin tick floating above the bar, in fog so it reads as a
                    // separate mark rather than more bar.
                    glyph = "▔"
                    style = Style(fg: Palette.fog, bg: background)
                } else {
                    glyph = " "
                }

                for column in 0..<columns {
                    screen.put(glyph, x: x0 + column, y: y, style: style)
                }
            }
        }
    }
}

// MARK: - Oscilloscope

/// A Braille canvas: each cell carries 2×4 addressable dots, so a waveform gets
/// eight times the vertical resolution of block glyphs and reads as a line rather
/// than a staircase.
///
/// Braille patterns live at U+2800 + bitmask. The bit layout is historical, not
/// raster order, which is why the mapping below is a table rather than a shift.
struct BrailleCanvas {
    let columns: Int
    let rows: Int
    private var dots: [UInt8]

    var dotWidth: Int { columns * 2 }
    var dotHeight: Int { rows * 4 }

    init(columns: Int, rows: Int) {
        self.columns = max(0, columns)
        self.rows = max(0, rows)
        dots = Array(repeating: 0, count: self.columns * self.rows)
    }

    private static func bit(x: Int, y: Int) -> UInt8 {
        if y == 3 { return x == 0 ? 0x40 : 0x80 }
        return UInt8(1 << (y + 3 * x))
    }

    mutating func plot(x: Int, y: Int) {
        guard x >= 0, y >= 0, x < dotWidth, y < dotHeight else { return }
        let cell = (y / 4) * columns + (x / 2)
        dots[cell] |= Self.bit(x: x % 2, y: y % 4)
    }

    /// Draws a vertical run, so consecutive samples join into a continuous trace
    /// instead of a dotted scatter.
    mutating func plotColumn(x: Int, from: Int, to: Int) {
        let low = min(from, to), high = max(from, to)
        for y in low...high { plot(x: x, y: y) }
    }

    func glyph(column: Int, row: Int) -> Character? {
        guard column >= 0, row >= 0, column < columns, row < rows else { return nil }
        let mask = dots[row * columns + column]
        guard mask != 0 else { return nil }
        return Character(UnicodeScalar(0x2800 + UInt32(mask))!)
    }
}

/// Oscilloscope view of the raw waveform.
///
/// Deliberately different in character from the bars: the spectrum shows *what*
/// frequencies are present, this shows the shape of the signal itself, so the two
/// are worth having rather than being two skins on the same data.
public struct ScopeMeter {
    public init() {}

    /// Samples to ask the analyser for, given a rect width.
    public func sampleCount(forWidth width: Int) -> Int {
        max(1, width * 2)
    }

    public func draw(
        in rect: Rect,
        on screen: Screen,
        samples: [Double],
        background: Color = Palette.ink
    ) {
        guard !rect.isEmpty, !samples.isEmpty else { return }

        var canvas = BrailleCanvas(columns: rect.width, rows: rect.height)
        let centre = canvas.dotHeight / 2

        func dotRow(_ value: Double) -> Int {
            let clamped = min(max(value, -1), 1)
            let row = Double(centre) - clamped * Double(centre - 1)
            return min(canvas.dotHeight - 1, max(0, Int(row.rounded())))
        }

        var previous = dotRow(samples[0])
        for x in 0..<canvas.dotWidth {
            let index = min(samples.count - 1, x * samples.count / canvas.dotWidth)
            let current = dotRow(samples[index])
            canvas.plotColumn(x: x, from: previous, to: current)
            previous = current
        }

        for row in 0..<rect.height {
            for column in 0..<rect.width {
                let y = rect.minY + row
                let x = rect.minX + column
                guard let glyph = canvas.glyph(column: column, row: row) else {
                    screen.put(" ", x: x, y: y, style: Style(fg: Palette.fog, bg: background))
                    continue
                }
                // Amber-dark along the zero line, bright amber at the extremes —
                // loud passages read hotter without needing a second colour.
                let distance = rect.height > 1
                    ? abs(Double(row) - Double(rect.height - 1) / 2) / (Double(rect.height - 1) / 2)
                    : 0
                let color = Palette.amberDark.mix(Palette.amber, min(1, distance * 1.3))
                screen.put(glyph, x: x, y: y, style: Style(fg: color, bg: background))
            }
        }

        // A faint dotted centre line gives the trace something to sit against
        // when the signal is quiet. Every other column, so it reads as a guide
        // rather than competing with the waveform.
        if rect.height >= 3 {
            let row = rect.height / 2
            let y = rect.minY + row
            for column in stride(from: 0, to: rect.width, by: 2)
            where canvas.glyph(column: column, row: row) == nil {
                screen.put(
                    "·",
                    x: rect.minX + column,
                    y: y,
                    style: Style(fg: Palette.panel.mix(Palette.mute, 0.35), bg: background)
                )
            }
        }
    }
}
