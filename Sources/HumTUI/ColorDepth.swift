import Darwin
import Foundation

/// How many colours the attached terminal can actually render.
///
/// This matters more than it looks. A terminal that only understands indexed
/// colour (`38;5;N`) and is handed a truecolor sequence (`38;2;R;G;B`) consumes
/// the `2` as the colour *index* — and index 2 is green. Emitting truecolor
/// unconditionally turns the whole amber palette green on macOS Terminal.app.
public enum ColorDepth: String, Sendable, CaseIterable {
    /// 24-bit `38;2;R;G;B`. iTerm2, Kitty, WezTerm, Ghostty, Alacritty, VS Code.
    case truecolor
    /// xterm-256 `38;5;N`. Terminal.app, most tmux/screen setups.
    case indexed256
    /// The original 8 + 8 bright. Very old terminals and `TERM=xterm`.
    case basic16
    /// No escapes at all.
    case none

    /// Detected once from the environment.
    ///
    /// Override with `HUM_COLOR=truecolor|indexed256|basic16|none` when the
    /// heuristics guess wrong — `COLORTERM` is set by the terminal, not the
    /// shell, so it goes missing over ssh and inside some multiplexers.
    public static let detected: ColorDepth = detect()

    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isTTY: Bool = isatty(STDOUT_FILENO) == 1
    ) -> ColorDepth {
        if let override = environment["HUM_COLOR"]?.lowercased(),
           let depth = ColorDepth(rawValue: override) {
            return depth
        }
        // Honour the de-facto standard for "please don't".
        if environment["NO_COLOR"] != nil { return .none }
        guard isTTY else { return .none }

        let term = (environment["TERM"] ?? "").lowercased()
        if term.isEmpty || term == "dumb" { return .none }

        // Terminals that support truecolor advertise it here.
        let colorterm = (environment["COLORTERM"] ?? "").lowercased()
        if colorterm == "truecolor" || colorterm == "24bit" { return .truecolor }

        // terminfo's direct-colour convention, e.g. xterm-direct, tmux-direct.
        if term.contains("direct") { return .truecolor }

        // Known-good terminals that sometimes fail to export COLORTERM, most
        // often over ssh.
        if environment["TERM_PROGRAM"].map(isTruecolorTerminal) == true { return .truecolor }
        if environment["KITTY_WINDOW_ID"] != nil { return .truecolor }
        if environment["WEZTERM_PANE"] != nil { return .truecolor }
        if environment["ALACRITTY_WINDOW_ID"] != nil { return .truecolor }
        if environment["GHOSTTY_RESOURCES_DIR"] != nil { return .truecolor }

        if term.contains("256color") { return .indexed256 }
        return .basic16
    }

    private static func isTruecolorTerminal(_ name: String) -> Bool {
        // Apple_Terminal is deliberately absent: it is the one that renders
        // truecolor as green.
        ["iterm.app", "wezterm", "ghostty", "kitty", "hyper", "tabby", "vscode", "warpterminal"]
            .contains(name.lowercased())
    }
}

// MARK: - Perceptual colour space

/// CIELAB, for judging which palette entry *looks* closest.
///
/// Distance in RGB is not distance to the eye. The practical consequence for a
/// 256-colour terminal: a channel-weighted RGB metric sends dark warm tones to
/// the grey ramp, because the colour cube's dark end jumps 0 → 95 and nothing
/// warm sits nearby in RGB terms. Lab keeps lightness and chroma apart, so a
/// slightly-wrong lightness with the right hue can beat an exact lightness with
/// no hue at all.
struct Lab {
    let l: Double, a: Double, b: Double

    init(_ color: Color) {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = linear(color.r), g = linear(color.g), bl = linear(color.b)

        // sRGB → XYZ, D65.
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * bl
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883

        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3) : (7.787 * t) + 16.0 / 116
        }
        let fx = f(x), fy = f(y), fz = f(z)

        l = 116 * fy - 16
        a = 500 * (fx - fy)
        b = 200 * (fy - fz)
    }

    /// Squared CIE76 difference. The ordering is all that matters here, so the
    /// square root is skipped; CIEDE2000 would be more accurate still and is not
    /// worth its cost for picking between thirty candidates.
    func squaredDifference(to other: Lab) -> Double {
        let dl = l - other.l, da = a - other.a, db = b - other.b
        return dl * dl + da * da + db * db
    }
}

/// Lab for every xterm-256 entry, built once.
private let paletteLab: [Lab] = (0..<256).map { Lab(Color.fromIndexed256(UInt8($0))) }

private let cubeLevels: [Int] = [0, 95, 135, 175, 215, 255]

// MARK: - Palette quantisation

extension Color {
    /// The xterm-256 index that looks closest to this colour.
    ///
    /// Candidates are generated cheaply — the 3×3×3 cube entries around the
    /// per-channel nearest, plus the three nearest greys — and then scored
    /// perceptually in Lab. Scoring all 240 entries would be more thorough and
    /// far too slow for a per-cell call in the render loop; the true match is
    /// always inside that neighbourhood.
    public var indexed256: UInt8 {
        let target = Lab(self)

        func nearestLevel(_ value: Int) -> Int {
            var best = 0, bestDistance = Int.max
            for (index, level) in cubeLevels.enumerated() {
                let distance = abs(level - value)
                if distance < bestDistance { bestDistance = distance; best = index }
            }
            return best
        }

        var bestIndex = 16
        var bestDistance = Double.greatestFiniteMagnitude

        func consider(_ index: Int) {
            guard index >= 16, index < 256 else { return }
            let distance = target.squaredDifference(to: paletteLab[index])
            if distance < bestDistance { bestDistance = distance; bestIndex = index }
        }

        let centreR = nearestLevel(Int(r))
        let centreG = nearestLevel(Int(g))
        let centreB = nearestLevel(Int(b))
        for dr in -1...1 {
            for dg in -1...1 {
                for db in -1...1 {
                    let cr = centreR + dr, cg = centreG + dg, cb = centreB + db
                    guard (0...5).contains(cr), (0...5).contains(cg), (0...5).contains(cb) else { continue }
                    consider(16 + 36 * cr + 6 * cg + cb)
                }
            }
        }

        // Grey ramp: 232 + n is grey 8 + 10n.
        let greyCentre = ((Int(r) + Int(g) + Int(b)) / 3 - 8 + 5) / 10
        for offset in -1...1 {
            let step = greyCentre + offset
            guard (0...23).contains(step) else { continue }
            consider(232 + step)
        }
        // Pure black and white live in the cube, not the ramp.
        consider(16)
        consider(231)

        return UInt8(bestIndex)
    }

    /// The nearest of the 16 ANSI colours, as an index 0–15.
    public var basic16: UInt8 {
        let target = Lab(self)
        var best = 7
        var bestDistance = Double.greatestFiniteMagnitude
        for index in 0..<16 {
            let distance = target.squaredDifference(to: Lab(Color.fromIndexed256(UInt8(index))))
            if distance < bestDistance { bestDistance = distance; best = index }
        }
        return UInt8(best)
    }

    /// The RGB an xterm-256 index actually displays as.
    public static func fromIndexed256(_ index: UInt8) -> Color {
        let value = Int(index)
        if value >= 232 {
            let grey = UInt8(8 + (value - 232) * 10)
            return Color(r: grey, g: grey, b: grey)
        }
        guard value >= 16 else {
            // The low 16 are theme-dependent; approximate with xterm defaults.
            let palette: [(UInt8, UInt8, UInt8)] = [
                (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
                (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
                (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
                (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
            ]
            let entry = palette[value]
            return Color(r: entry.0, g: entry.1, b: entry.2)
        }
        let offset = value - 16
        return Color(
            r: UInt8(cubeLevels[offset / 36]),
            g: UInt8(cubeLevels[(offset % 36) / 6]),
            b: UInt8(cubeLevels[offset % 6])
        )
    }

    /// The colour the terminal will actually show for this one.
    ///
    /// Needed to dither: error diffusion has to know what was really displayed
    /// in order to carry the difference forward.
    public func displayed(at depth: ColorDepth) -> Color {
        switch depth {
        case .truecolor, .none: return self
        case .indexed256: return Color.fromIndexed256(indexed256)
        case .basic16: return Color.fromIndexed256(basic16)
        }
    }

    /// The SGR parameters that set this colour, for the given depth.
    public func sgrParameters(foreground: Bool, depth: ColorDepth) -> [String] {
        switch depth {
        case .none:
            return []
        case .truecolor:
            return ["\(foreground ? 38 : 48);2;\(r);\(g);\(b)"]
        case .indexed256:
            return ["\(foreground ? 38 : 48);5;\(indexed256)"]
        case .basic16:
            let index = basic16
            if index < 8 {
                return ["\(Int(index) + (foreground ? 30 : 40))"]
            }
            return ["\(Int(index) - 8 + (foreground ? 90 : 100))"]
        }
    }
}
