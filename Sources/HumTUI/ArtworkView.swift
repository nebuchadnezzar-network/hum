import Foundation

/// Decoded RGBA pixels, ready to be drawn into terminal cells.
///
/// Kept free of CoreGraphics so `HumTUI` stays a pure terminal library — the
/// decoding lives next to whoever fetched the bytes.
public struct PixelImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Row-major RGBA, 4 bytes per pixel.
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public func pixel(x: Int, y: Int) -> Color {
        guard x >= 0, y >= 0, x < width, y < height else { return Palette.ink }
        let offset = (y * width + x) * 4
        guard offset + 2 < rgba.count else { return Palette.ink }
        return Color(r: rgba[offset], g: rgba[offset + 1], b: rgba[offset + 2])
    }
}

/// How to turn pixels into characters.
public enum ArtworkStyle: String, Sendable, CaseIterable {
    /// Quadrant blocks (`▘▝▀▖▌▞▛▗▚▐▜▄▙▟█`): 2×2 subcells per character, so four
    /// source pixels per cell instead of two. Twice the horizontal detail of
    /// half-blocks, at the cost of approximating those four pixels with the two
    /// colours a cell can carry.
    case quadrant
    /// `▀` with foreground as the upper pixel and background as the lower one.
    /// Two pixels per cell, each reproduced exactly — smoother on gradients,
    /// softer on edges.
    case halfBlock
    /// A luminance ramp. Genuinely ASCII, and the right answer when the terminal
    /// has few or no colours.
    case ascii

    /// Block glyphs need colour to mean anything; below that, use the ramp.
    ///
    /// Half-block is the default despite quadrant resolving twice the detail,
    /// because the extra detail does not pay for itself on the content album art
    /// usually is. Measured as RMS error against the source, at 24x12 cells:
    ///
    /// | content | quadrant | halfBlock |
    /// |---|---|---|
    /// | photographic, truecolor | 3.0 | 3.8 |
    /// | photographic, 256 colour | 13.7 | 13.8 |
    /// | graphic / high contrast, 256 colour | 18.1 | 57.1 |
    ///
    /// On a photograph the two are indistinguishable by error, so quadrant's 2x2
    /// structure is pure added texture — it reads as dithering for no gain. On
    /// graphic covers it is three times more faithful and clearly worth having.
    /// Since most covers are photographs, half-block is the better default and
    /// `HUM_ART=quadrant` is there for the rest.
    public static func best(for depth: ColorDepth) -> ArtworkStyle {
        if let raw = ProcessInfo.processInfo.environment["HUM_ART"],
           let style = ArtworkStyle(rawValue: raw) {
            return style
        }
        switch depth {
        case .truecolor, .indexed256: return .halfBlock
        case .basic16, .none: return .ascii
        }
    }
}

/// Pixels per cell differ by style, so the caller has to ask before sizing a
/// decode request.
public func artworkPixelSize(cells: (width: Int, height: Int), style: ArtworkStyle) -> (width: Int, height: Int) {
    switch style {
    case .quadrant: return (cells.width * 2, cells.height * 2)
    case .halfBlock: return (cells.width, cells.height * 2)
    case .ascii: return (cells.width, cells.height)
    }
}

/// Rows needed to draw a square image `width` columns wide.
///
/// Terminal cells are about twice as tall as they are wide, so a square image
/// wants half as many rows as columns. This is a property of the terminal, not of
/// the rendering style — the styles differ in how many pixels they sample into
/// those cells (half-block two rows per cell, ASCII one), not in cells occupied.
public func artworkRows(forWidth width: Int) -> Int {
    max(1, width / 2)
}

/// Two leading spaces on purpose: album art is usually dark, and mapping the
/// bottom of the range to a dot turns every shadow into visual noise. Blank below
/// about 15% luma reads as black, which is what it is.
private let luminanceRamp = Array("  .·:-=+*#%@")

/// Quadrant glyphs indexed by a 4-bit mask of which subcells are foreground:
/// bit 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
private let quadrantGlyphs: [Character] = [
    " ", "▘", "▝", "▀",
    "▖", "▌", "▞", "▛",
    "▗", "▚", "▐", "▜",
    "▄", "▙", "▟", "█",
]

private func luma(_ color: Color) -> Double {
    // Rec. 601, matching how bright the eye finds each channel.
    (0.299 * Double(color.r) + 0.587 * Double(color.g) + 0.114 * Double(color.b)) / 255
}

private func squaredDistance(_ a: Color, _ b: Color) -> Int {
    let dr = Int(a.r) - Int(b.r), dg = Int(a.g) - Int(b.g), db = Int(a.b) - Int(b.b)
    return dr * dr + dg * dg + db * db
}

private func average(_ colors: [Color]) -> Color {
    guard !colors.isEmpty else { return Palette.ink }
    var r = 0, g = 0, b = 0
    for color in colors {
        r += Int(color.r)
        g += Int(color.g)
        b += Int(color.b)
    }
    let count = colors.count
    return Color(r: UInt8(r / count), g: UInt8(g / count), b: UInt8(b / count))
}

/// Chooses how to draw one cell from its four source pixels.
///
/// A cell can hold two colours. Four pixels therefore have to be reduced to
/// either one colour (a solid block) or two plus a pattern — and the choice is
/// made by comparing *error*, not by thresholding how different the pixels are.
///
/// That distinction is the whole game. An absolute difference threshold fires on
/// film grain, so photographic covers come out with a pattern in nearly every
/// cell and read as heavy dithering. What matters is whether a pattern *explains*
/// the cell better than a flat colour does, by enough to be worth the structure
/// it adds: the eye notices invented texture far more than a small colour error.
///
/// All fourteen patterns are evaluated rather than clustered towards, which is
/// both exhaustive and cheaper than it sounds — 14 masks over 4 pixels, once per
/// cell, only on a cache miss.
private func quadrantCell(_ pixels: [Color]) -> (glyph: Character, foreground: Color, background: Color) {
    let flat = average(pixels)
    let flatError = pixels.reduce(0) { $0 + squaredDistance($1, flat) }

    var bestMask = 0
    var bestError = Int.max
    var bestForeground = flat
    var bestBackground = flat

    for mask in 1..<15 {
        var foreground: [Color] = []
        var background: [Color] = []
        for (index, pixel) in pixels.enumerated() {
            if mask & (1 << index) != 0 {
                foreground.append(pixel)
            } else {
                background.append(pixel)
            }
        }
        let foregroundMean = average(foreground)
        let backgroundMean = average(background)

        var error = 0
        for pixel in foreground { error += squaredDistance(pixel, foregroundMean) }
        for pixel in background { error += squaredDistance(pixel, backgroundMean) }

        if error < bestError {
            bestError = error
            bestMask = mask
            bestForeground = foregroundMean
            bestBackground = backgroundMean
        }
    }

    guard bestError + patternPenalty(forMask: bestMask) < flatError else {
        return ("█", flat, flat)
    }
    return (quadrantGlyphs[bestMask], bestForeground, bestBackground)
}

/// How much better than a flat cell a pattern must be before it is used, by how
/// much visual structure the pattern invents.
///
/// Patterns are not equally risky. A contiguous half-split (`▀▄▌▐`) is exactly
/// the structure half-blocks draw all the time and reads as smooth shading, so it
/// needs almost no justification. A diagonal (`▚▞`) is a checkerboard — it is
/// what dithering looks like — and on noisy source material it will win on raw
/// error while looking terrible, so it has to clear a much higher bar.
///
/// Returned in the same units as the error sums: a per-channel tolerance over
/// four pixels and three channels, so the tolerances below read as "roughly this
/// many levels per channel".
private func patternPenalty(forMask mask: Int) -> Int {
    let tolerance: Int
    switch mask {
    case 0b0011, 0b1100:
        // ▀ ▄ — a vertical split is *precisely* what half-block rendering does,
        // in the same glyph, so there is nothing to justify: take it whenever it
        // beats a flat cell at all. This is what keeps quadrant from having less
        // colour resolution than half-block on smooth photographic covers.
        tolerance = 2
    case 0b0101, 0b1010:
        // ▌ ▐ — the horizontal equivalent, and the detail half-blocks cannot
        // show. Contiguous, so still smooth; a touch more cautious only because
        // vertical striping is less familiar to the eye than horizontal.
        tolerance = 4
    case 0b0110, 0b1001:
        // ▞ ▚ — diagonal checkerboards. This is what dithering looks like, and
        // on noisy material it wins on raw error while looking terrible.
        tolerance = 44
    default:
        // Single corners and three-quadrant shapes: real edge features.
        tolerance = 13
    }
    return 4 * 3 * tolerance * tolerance
}

/// Floyd–Steinberg error diffusion over the colours a half-block render will
/// emit.
///
/// Without this, an indexed terminal destroys dark artwork: the xterm-256 cube
/// jumps from 0 to 95 at the dark end, so every dark saturated colour is nearer
/// the 24-step grey ramp than to any cube entry, and a dark cover collapses to a
/// handful of near-identical greys. Measured on one: 225 distinct colours at
/// truecolor became 10, and 80% of cells lost their top/bottom distinction
/// entirely.
///
/// Diffusing the quantisation error into neighbouring cells recovers both. Note
/// this is palette dithering *between* cells, which is the standard answer to a
/// coarse palette — not structural patterning inside a cell, which is what makes
/// terminal art look like noise.
///
/// Half-block only: its output grid is exactly one colour per subcell, which is
/// what error diffusion needs. Quadrant packs four subcells into two colours, so
/// there is no such grid to diffuse over.

/// How much of each cell's quantisation error is pushed into its neighbours.
///
/// Full-strength diffusion assumes the dither pattern is finer than the eye can
/// resolve. Here a "pixel" is half a terminal cell — large on screen — so the
/// pattern reads as grain rather than blending.
///
/// Measured on a dark cover at 32×16 cells, as Lab ΔE against the source:
///
/// | strength | per-pixel | after a one-cell blur |
/// |---|---|---|
/// | 0.0 (off) | 15.7 | 15.4 |
/// | 0.6 | 20.1 | 7.9 |
/// | 1.0 (full) | 23.7 | 5.8 |
///
/// Full strength is nearly three times better once neighbours are integrated,
/// and worse if they are not — so the right value depends on the font size and
/// how close you sit, which no measurement here can settle. `HUM_DITHER=0...1`
/// exposes it; 0 turns dithering off entirely.
public let artworkDitherStrength: Double = {
    if let raw = ProcessInfo.processInfo.environment["HUM_DITHER"],
       let value = Double(raw) {
        return min(max(value, 0), 1)
    }
    return 0.6
}()

private func ditheredHalfBlock(
    _ image: PixelImage,
    rect: Rect,
    depth: ColorDepth,
    strength: Double
) -> [Color] {
    let width = rect.width
    let height = rect.height * 2

    // Desired colour per subcell, in floating point so error can accumulate,
    // plus an untouched copy for deciding where dithering is wanted at all.
    var desired = [Double](repeating: 0, count: width * height * 3)
    var original = [Double](repeating: 0, count: width * height * 3)
    for row in 0..<height {
        for column in 0..<width {
            let x = min(image.width - 1, column * image.width / width)
            let y = min(image.height - 1, row * image.height / height)
            let pixel = image.pixel(x: x, y: y)
            let offset = (row * width + column) * 3
            desired[offset] = Double(pixel.r)
            desired[offset + 1] = Double(pixel.g)
            desired[offset + 2] = Double(pixel.b)
            original[offset] = Double(pixel.r)
            original[offset + 1] = Double(pixel.g)
            original[offset + 2] = Double(pixel.b)
        }
    }

    /// Whether the source is uniform around this subcell.
    ///
    /// Dithering a flat region is pure cost: there is no detail to resolve, and
    /// the pattern is the only thing it adds. That matters most exactly where it
    /// hurts most — the colour cube's levels are 40 apart at the saturated end,
    /// so a flat red field checkerboards between #AF0000 and #D70000, which is
    /// very loud.
    ///
    /// The window is deliberately wide and the tolerance tight, so a slow
    /// gradient — which *does* want dithering, and bands badly without it — is
    /// not mistaken for a flat field. A gradient varies across a wide window
    /// even when adjacent pixels look identical.
    func isFlat(column: Int, row: Int) -> Bool {
        let radius = 2
        let tolerance = 4.0
        let centre = (row * width + column) * 3
        for dy in -radius...radius {
            for dx in -radius...radius {
                let nx = column + dx, ny = row + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let other = (ny * width + nx) * 3
                for channel in 0..<3 {
                    if abs(original[centre + channel] - original[other + channel]) > tolerance {
                        return false
                    }
                }
            }
        }
        return true
    }

    var output = [Color](repeating: Palette.ink, count: width * height)

    func clampByte(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, value.rounded())))
    }

    for row in 0..<height {
        // Serpentine: alternate the scan direction each row. Always scanning
        // left-to-right makes the error travel the same way everywhere, which
        // shows up as diagonal worming across flat areas — very visible at this
        // resolution, where one cell is a large fraction of the picture.
        let leftToRight = row % 2 == 0
        let columns = leftToRight
            ? Array(0..<width)
            : Array((0..<width).reversed())
        let forward = leftToRight ? 1 : -1

        for column in columns {
            let offset = (row * width + column) * 3

            // Flat regions take the palette's best single answer and neither
            // accept nor emit error, so a solid colour stays solid.
            if isFlat(column: column, row: row) {
                let exact = Color(
                    r: clampByte(original[offset]),
                    g: clampByte(original[offset + 1]),
                    b: clampByte(original[offset + 2])
                )
                output[row * width + column] = exact.displayed(at: depth)
                continue
            }

            let wanted = Color(
                r: clampByte(desired[offset]),
                g: clampByte(desired[offset + 1]),
                b: clampByte(desired[offset + 2])
            )
            let shown = wanted.displayed(at: depth)
            output[row * width + column] = shown

            // Error against the unclamped desire, so highlights and shadows
            // still push their neighbours. Bounded, because the palette has
            // nothing at all in some regions and an unbounded residue there
            // turns into visible speckle rather than a better average.
            func bounded(_ value: Double) -> Double { min(max(value, -64), 64) }
            let error = (
                bounded(desired[offset] - Double(shown.r)),
                bounded(desired[offset + 1] - Double(shown.g)),
                bounded(desired[offset + 2] - Double(shown.b))
            )

            func diffuse(_ dx: Int, _ dy: Int, _ weight: Double) {
                let nx = column + dx * forward, ny = row + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { return }
                let target = (ny * width + nx) * 3
                desired[target] += error.0 * weight
                desired[target + 1] += error.1 * weight
                desired[target + 2] += error.2 * weight
            }
            // Floyd–Steinberg, mirrored on right-to-left rows and scaled.
            diffuse(1, 0, 7.0 / 16 * strength)
            diffuse(-1, 1, 3.0 / 16 * strength)
            diffuse(0, 1, 5.0 / 16 * strength)
            diffuse(1, 1, 1.0 / 16 * strength)
        }
    }
    return output
}

public func drawArtwork(
    _ image: PixelImage,
    in rect: Rect,
    on screen: Screen,
    style: ArtworkStyle,
    background: Color = Palette.ink,
    ditherStrength: Double = artworkDitherStrength
) {
    guard !rect.isEmpty, image.width > 0, image.height > 0 else { return }

    // On an indexed terminal the palette, not the glyph, is what limits the
    // picture — so spend the effort there.
    if style == .halfBlock, screen.colorDepth == .indexed256 || screen.colorDepth == .basic16 {
        let dithered = ditheredHalfBlock(
            image,
            rect: rect,
            depth: screen.colorDepth,
            strength: ditherStrength
        )
        for row in 0..<rect.height {
            for column in 0..<rect.width {
                let top = dithered[(row * 2) * rect.width + column]
                let bottom = dithered[(row * 2 + 1) * rect.width + column]
                screen.put(
                    "▀",
                    x: rect.minX + column,
                    y: rect.minY + row,
                    style: Style(fg: top, bg: bottom)
                )
            }
        }
        return
    }

    for row in 0..<rect.height {
        for column in 0..<rect.width {
            let y = rect.minY + row
            let screenX = rect.minX + column

            switch style {
            case .quadrant:
                // Source coordinates are mapped proportionally rather than
                // assumed, so an image that is not exactly the requested size
                // still renders (just softer).
                func sample(_ dx: Int, _ dy: Int) -> Color {
                    let sx = min(image.width - 1, (column * 2 + dx) * image.width / (rect.width * 2))
                    let sy = min(image.height - 1, (row * 2 + dy) * image.height / (rect.height * 2))
                    return image.pixel(x: sx, y: sy)
                }
                let cell = quadrantCell([sample(0, 0), sample(1, 0), sample(0, 1), sample(1, 1)])
                screen.put(
                    cell.glyph,
                    x: screenX,
                    y: y,
                    style: Style(fg: cell.foreground, bg: cell.background)
                )

            case .halfBlock:
                let x = min(image.width - 1, column * image.width / rect.width)
                let topY = min(image.height - 1, (row * 2) * image.height / (rect.height * 2))
                let bottomY = min(image.height - 1, (row * 2 + 1) * image.height / (rect.height * 2))
                screen.put(
                    "▀",
                    x: screenX,
                    y: y,
                    style: Style(fg: image.pixel(x: x, y: topY), bg: image.pixel(x: x, y: bottomY))
                )

            case .ascii:
                let x = min(image.width - 1, column * image.width / rect.width)
                let sourceY = min(image.height - 1, row * image.height / rect.height)
                let color = image.pixel(x: x, y: sourceY)
                // Lift the midtones: with only a dozen ramp steps, a linear map
                // leaves most covers sitting in the bottom two or three.
                let brightness = pow(luma(color), 0.72)
                let index = min(luminanceRamp.count - 1, Int(brightness * Double(luminanceRamp.count)))
                screen.put(
                    luminanceRamp[index],
                    x: screenX,
                    y: y,
                    style: Style(fg: Palette.amberDark.mix(Palette.amber, brightness), bg: background)
                )
            }
        }
    }
}
