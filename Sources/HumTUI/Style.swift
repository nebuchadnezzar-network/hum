import Foundation

/// A 24-bit colour. Quantised down to indexed or basic ANSI when the terminal
/// cannot do truecolor — see `ColorDepth`.
public struct Color: Equatable, Sendable {
    public let r: UInt8, g: UInt8, b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: UInt32) {
        self.init(
            r: UInt8((hex >> 16) & 0xFF),
            g: UInt8((hex >> 8) & 0xFF),
            b: UInt8(hex & 0xFF)
        )
    }

    /// Linear blend towards `other`. Used for the fading spectrum and dimmed rows.
    public func mix(_ other: Color, _ t: Double) -> Color {
        let t = min(max(t, 0), 1)
        func lerp(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(max(0, min(255, Double(a) + (Double(b) - Double(a)) * t)))
        }
        return Color(r: lerp(r, other.r), g: lerp(g, other.g), b: lerp(b, other.b))
    }
}

/// The hum palette, lifted verbatim from `branding/text-icons.txt`.
public enum Palette {
    public static let ink = Color(hex: 0x0E1116)
    public static let panel = Color(hex: 0x161B22)
    public static let amber = Color(hex: 0xF2A93B)
    public static let amberDark = Color(hex: 0xB8700A)
    public static let fog = Color(hex: 0xC9D1D9)
    public static let mute = Color(hex: 0x8B949E)
    public static let lightBackground = Color(hex: 0xF6F4EF)

    /// Panel borders sit between panel and mute so they recede behind content.
    public static let border = Color(hex: 0x161B22).mix(Color(hex: 0x8B949E), 0.45)
}

public struct Attributes: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let bold = Attributes(rawValue: 1 << 0)
    public static let dim = Attributes(rawValue: 1 << 1)
    public static let italic = Attributes(rawValue: 1 << 2)
    public static let underline = Attributes(rawValue: 1 << 3)
    public static let reverse = Attributes(rawValue: 1 << 4)
}

/// Everything needed to paint one cell apart from its character.
public struct Style: Equatable, Sendable {
    public var fg: Color
    public var bg: Color
    public var attributes: Attributes

    public init(fg: Color = Palette.fog, bg: Color = Palette.ink, attributes: Attributes = []) {
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
    }

    public static let `default` = Style()

    public func fg(_ color: Color) -> Style { Style(fg: color, bg: bg, attributes: attributes) }
    public func bg(_ color: Color) -> Style { Style(fg: fg, bg: color, attributes: attributes) }
    public func with(_ extra: Attributes) -> Style {
        Style(fg: fg, bg: bg, attributes: attributes.union(extra))
    }

    /// The SGR sequence that takes the terminal from a bare state into this style.
    /// `Screen` resets between runs rather than tracking deltas per attribute;
    /// one reset per style change is cheap and keeps the diff logic honest.
    public func sgr(depth: ColorDepth = .detected) -> String {
        guard depth != .none else { return "" }
        var codes = ["0"]
        if attributes.contains(.bold) { codes.append("1") }
        if attributes.contains(.dim) { codes.append("2") }
        if attributes.contains(.italic) { codes.append("3") }
        if attributes.contains(.underline) { codes.append("4") }
        if attributes.contains(.reverse) { codes.append("7") }
        codes.append(contentsOf: fg.sgrParameters(foreground: true, depth: depth))
        codes.append(contentsOf: bg.sgrParameters(foreground: false, depth: depth))
        return "\u{1B}[" + codes.joined(separator: ";") + "m"
    }
}
