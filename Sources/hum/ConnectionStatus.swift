import Foundation
import HumPlex
import HumTUI

/// What the header says about the server.
///
/// Its own type rather than a couple of booleans on the screen, because the
/// three states are not independent: connecting is not "not connected", and an
/// offline indicator that appears while the first request is still in flight is
/// worse than no indicator at all.
enum ConnectionStatus: Equatable {
    case connecting
    /// Connected. `route` is local, remote or relay — worth showing, because a
    /// relay connection is bandwidth-capped by plex.tv and that explains
    /// stuttering that otherwise looks like a hum problem.
    case online(route: String, name: String)
    case offline

    /// Filled for connected, hollow for not, half for in between. The shape
    /// carries the meaning on its own, so the indicator still reads in a
    /// monochrome terminal and for a reader who cannot tell the colours apart.
    var glyph: String {
        switch self {
        case .connecting: return "◌"
        case .online: return "●"
        case .offline: return "○"
        }
    }

    /// The short form, for a narrow terminal.
    var label: String {
        switch self {
        case .connecting: return "connecting"
        case .online(let route, _): return route
        case .offline: return "offline"
        }
    }

    /// The long form: the server's name as well as the route.
    var detailedLabel: String {
        switch self {
        case .online(let route, let name): return "\(name) · \(route)"
        case .connecting, .offline: return label
        }
    }

    /// The indicator's colour. On the type rather than in the draw path, so it
    /// is covered by the same tests as the glyph.
    var color: Color {
        switch self {
        case .online: return Palette.online
        case .connecting: return Palette.amber
        case .offline: return Palette.mute
        }
    }

    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }
}
