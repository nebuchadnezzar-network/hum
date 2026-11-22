import Darwin
import Foundation

public enum Key: Equatable, Sendable {
    case character(Character)
    case control(Character)  // the letter, e.g. .control("c") for Ctrl-C
    case up, down, left, right
    case home, end, pageUp, pageDown
    case enter, tab, backTab, backspace, delete, escape
    case function(Int)
    case unknown
}

/// Blocking stdin decoder. Lives on its own thread: `next()` parks in `read(2)`
/// until a byte arrives, so an idle hum burns no CPU.
public final class InputReader {
    private var pending: [UInt8] = []

    public init() {}

    /// Reads one byte, waiting up to `timeout` milliseconds. A negative timeout
    /// blocks indefinitely. Returns nil on timeout or EOF.
    private func readByte(timeout: Int32 = -1) -> UInt8? {
        if let first = pending.first {
            pending.removeFirst()
            return first
        }
        if timeout >= 0 {
            var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            guard poll(&fd, 1, timeout) > 0 else { return nil }
        }
        var byte: UInt8 = 0
        let count = read(STDIN_FILENO, &byte, 1)
        guard count == 1 else { return nil }
        return byte
    }

    private func pushBack(_ bytes: [UInt8]) {
        pending.insert(contentsOf: bytes, at: 0)
    }

    public func next() -> Key? {
        guard let byte = readByte() else { return nil }

        switch byte {
        case 0x1B:
            return decodeEscape()
        case 0x0D, 0x0A:
            return .enter
        case 0x09:
            return .tab
        case 0x7F, 0x08:
            return .backspace
        case 0x01...0x1A:
            // Ctrl-A..Ctrl-Z, minus the ones handled above.
            let letter = Character(UnicodeScalar(byte + 0x60))
            return .control(letter)
        case 0x20...0x7E:
            return .character(Character(UnicodeScalar(byte)))
        default:
            return decodeUTF8(first: byte)
        }
    }

    /// Multi-byte UTF-8: the leading byte says how many continuation bytes follow.
    private func decodeUTF8(first: UInt8) -> Key {
        var bytes = [first]
        let extra: Int
        if first & 0xE0 == 0xC0 { extra = 1 }
        else if first & 0xF0 == 0xE0 { extra = 2 }
        else if first & 0xF8 == 0xF0 { extra = 3 }
        else { return .unknown }

        for _ in 0..<extra {
            guard let byte = readByte(timeout: 50) else { return .unknown }
            bytes.append(byte)
        }
        guard let string = String(bytes: bytes, encoding: .utf8), let character = string.first else {
            return .unknown
        }
        return .character(character)
    }

    /// ESC with nothing behind it is a real Escape press; the 25ms window is the
    /// usual compromise between that and a terminal splitting a CSI across reads.
    private func decodeEscape() -> Key {
        guard let second = readByte(timeout: 25) else { return .escape }

        switch second {
        case UInt8(ascii: "["):
            return decodeCSI()
        case UInt8(ascii: "O"):
            // SS3: numeric keypad / function keys in application mode.
            guard let third = readByte(timeout: 25) else { return .escape }
            switch third {
            case UInt8(ascii: "A"): return .up
            case UInt8(ascii: "B"): return .down
            case UInt8(ascii: "C"): return .right
            case UInt8(ascii: "D"): return .left
            case UInt8(ascii: "H"): return .home
            case UInt8(ascii: "F"): return .end
            case UInt8(ascii: "P"): return .function(1)
            case UInt8(ascii: "Q"): return .function(2)
            case UInt8(ascii: "R"): return .function(3)
            case UInt8(ascii: "S"): return .function(4)
            default: return .unknown
            }
        default:
            // Alt-<key> arrives as ESC followed by the key; treat it as the key.
            pushBack([second])
            return next() ?? .escape
        }
    }

    private func decodeCSI() -> Key {
        var parameters: [UInt8] = []
        // Collect the parameter/intermediate bytes, then the final byte in 0x40...0x7E.
        while let byte = readByte(timeout: 50) {
            if byte >= 0x40 && byte <= 0x7E {
                return finishCSI(final: byte, parameters: parameters)
            }
            parameters.append(byte)
            if parameters.count > 16 { return .unknown }
        }
        return .unknown
    }

    private func finishCSI(final: UInt8, parameters: [UInt8]) -> Key {
        let text = String(decoding: parameters, as: UTF8.self)
        switch final {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "C"): return .right
        case UInt8(ascii: "D"): return .left
        case UInt8(ascii: "H"): return .home
        case UInt8(ascii: "F"): return .end
        case UInt8(ascii: "Z"): return .backTab
        case UInt8(ascii: "~"):
            // ESC [ n ~ — the number before the tilde picks the key.
            let number = Int(text.split(separator: ";").first.map(String.init) ?? "") ?? 0
            switch number {
            case 1, 7: return .home
            case 2: return .unknown  // Insert
            case 3: return .delete
            case 4, 8: return .end
            case 5: return .pageUp
            case 6: return .pageDown
            case 11...15: return .function(number - 10)
            case 17...21: return .function(number - 11)
            case 23, 24: return .function(number - 12)
            default: return .unknown
            }
        default:
            return .unknown
        }
    }
}
