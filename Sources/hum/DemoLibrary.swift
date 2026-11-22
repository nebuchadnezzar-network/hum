import AppKit
import Foundation
import HumPlayer
import HumPlex

/// Synthetic library and playback, for `hum demo`.
///
/// Exists so the UI can be exercised — layout, scrolling, the spectrum, the
/// status line — without a Plex account, which is also how it gets checked in CI
/// and on a machine that has never been signed in.
final class DemoLibrary {
    private let events: EventQueue
    private var queue: [Track] = []
    private var index = 0
    /// Retires the previous tone thread when playback restarts.

    private static let catalogue: [(artist: String, genre: String, albums: [(String, Int, [String])])] = [
        ("Aphex Twin", "Electronic", [
            ("Selected Ambient Works 85–92", 1992, ["Xtal", "Tha", "Pulsewidth", "Ageispolis", "i", "Green Calx"]),
            ("Richard D. James Album", 1996, ["4", "Cornish Acid", "Peek 824545201", "Fingerbib"]),
        ]),
        ("Boards of Canada", "Electronic", [
            ("Music Has the Right to Children", 1998, ["Wildlife Analysis", "An Eagle in Your Mind", "Roygbiv", "Aquarius"]),
            ("Geogaddi", 2002, ["Ready Lets Go", "Music Is Math", "Julie and Candy", "Dawn Chorus"]),
        ]),
        ("Alice Coltrane", "Jazz", [
            ("Journey in Satchidananda", 1971, ["Journey in Satchidananda", "Shiva-Loka", "Stopover Bombay", "Isis and Osiris"]),
            ("Ptah, the El Daoud", 1970, ["Ptah, the El Daoud", "Turiya and Ramakrishna", "Blue Nile"]),
        ]),
        ("Talk Talk", "Rock", [
            ("Spirit of Eden", 1988, ["The Rainbow", "Eden", "Desire", "Inheritance", "I Believe in You"]),
            ("Laughing Stock", 1991, ["Myrrhman", "Ascension Day", "After the Flood", "New Grass"]),
        ]),
        ("Hiroshi Yoshimura", "Ambient", [
            ("Music for Nine Post Cards", 1982, ["Water Copy", "Clouds", "Blink", "Dance PM", "Curve"]),
            ("Green", 1986, ["Creek", "Feel", "Soft Stream", "Sheep", "Water Planet"]),
        ]),
        ("Sault", "Soul", [
            ("Untitled (Rise)", 2020, ["Strong", "Fearless", "Rise", "I Just Want to Dance", "Free"]),
        ]),
        ("Caterina Barbieri", "Electronic", [
            ("Ecstatic Computation", 2019, ["Fantas", "Closest Approach to Your Orbit", "Pinnacles of You"]),
        ]),
        ("Pharoah Sanders", "Jazz", [
            ("Karma", 1969, ["The Creator Has a Master Plan", "Colors"]),
            ("Thembi", 1971, ["Astral Travelling", "Red, Black & Green", "Love", "Morning Prayer"]),
        ]),
    ]

    init(events: EventQueue) {
        self.events = events
    }

    // MARK: - Library

    /// Stands in for server discovery. Returned rather than posted so `HumApp`
    /// can record it the same way it records a real connection.
    func connection() -> (PlexServer, [LibrarySection]) {
        let server = PlexServer(
            name: "demo",
            baseURL: URL(string: "http://127.0.0.1:32400")!,
            accessToken: "demo",
            isLocal: true,
            isRelay: false,
            clientIdentifier: "demo"
        )
        return (server, [LibrarySection(id: "demo", title: "Demo Music", type: "artist")])
    }

    func collections(mode: CollectionMode) -> [CollectionItem] {
        switch mode {
        case .artists:
            return Self.catalogue.map {
                CollectionItem(id: $0.artist, title: $0.artist, detail: $0.genre)
            }
        case .playlists:
            // Two flat lists, enough to exercise the pane collapsing and the
            // playlist-order path.
            return [
                CollectionItem(id: "demo:playlist:late", title: "late night", detail: "6"),
                // A deliberately stale count, the way a smart playlist's
                // computed `leafCount` can disagree with what its items
                // endpoint returns. Opening it should correct the row.
                CollectionItem(id: "demo:playlist:loud", title: "loud", detail: "12"),
            ]
        case .rated:
            return [CollectionItem(id: "hum:rated", title: "rated tracks", detail: nil)]
        default:
            // Facets are the distinct genre names; good enough to prove the mode
            // switch and the album filter wire up correctly.
            let genres = Array(Set(Self.catalogue.map(\.genre))).sorted()
            return genres.map { CollectionItem(id: $0, title: $0, detail: nil) }
        }
    }

    /// Tracks for a flat collection item: a demo playlist, or every rated track.
    func flatTracks(for id: String) -> [Track] {
        let everything = Self.catalogue.flatMap { entry in
            entry.albums.flatMap { album in tracks(albumID: "\(entry.artist)|\(album.0)") }
        }
        switch id {
        case "hum:rated":
            return everything
                .filter { ($0.userRating ?? 0) > 0 }
                .sorted { ($0.userRating ?? 0, $0.title) > ($1.userRating ?? 0, $1.title) }
        case "demo:playlist:late":
            return Array(everything.filter { $0.duration > 240 }.prefix(6))
        case "demo:playlist:loud":
            return Array(everything.filter { $0.hasLyrics }.prefix(4))
        default:
            return []
        }
    }

    func albums(for item: CollectionItem, mode: CollectionMode) -> [Album] {
        let entries: [(artist: String, genre: String, albums: [(String, Int, [String])])]
        switch mode {
        case .artists:
            entries = Self.catalogue.filter { $0.artist == item.id }
        default:
            entries = Self.catalogue.filter { $0.genre == item.id }
        }

        return entries.flatMap { entry in
            entry.albums.map { album in
                Album(
                    id: "\(entry.artist)|\(album.0)",
                    title: album.0,
                    artist: entry.artist,
                    artistID: entry.artist,
                    year: album.1,
                    thumb: nil,
                    genres: [entry.genre],
                    labels: []
                )
            }
        }
    }

    func tracks(albumID: String) -> [Track] {
        let parts = albumID.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let entry = Self.catalogue.first(where: { $0.artist == parts[0] }),
              let album = entry.albums.first(where: { $0.0 == parts[1] })
        else { return [] }

        return album.2.enumerated().map { index, title in
            Track(
                id: "\(albumID)|\(index)",
                title: title,
                album: album.0,
                albumID: albumID,
                artist: entry.artist,
                trackNumber: index + 1,
                discNumber: 1,
                // Short, because demo audio is generated on first play and a
                // five-minute track is 26MB of WAV to render before a note
                // sounds. Still varied, still stable between runs.
                duration: Double(24 + (title.count * 7) % 36),
                partKey: "/demo/\(albumID)/\(index)",
                thumb: "demo:\(albumID)",
                hasLyrics: index % 3 == 0,
                lyricsCandidatePaths: index % 3 == 0 ? ["/demo/lyrics"] : [],
                // A spread of ratings, including a half and some unrated, so
                // the column is exercised without changing between runs.
                albumYear: album.1,
                userRating: [nil, 10.0, nil, 6.0, 7.0, nil, 2.0][index % 7],
                codec: "flac",
                bitrate: 1024
            )
        }
    }

    /// Mirrors the real search: matches artists, albums and tracks separately,
    /// so the demo exercises the same three-pane result handling.
    func search(_ query: String) -> SearchResults {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return SearchResults() }

        var results = SearchResults()
        for item in collections(mode: .artists) where item.title.lowercased().contains(needle) {
            results.artists.append(
                Artist(id: item.id, title: item.title, albumCount: nil, thumb: nil, genres: [])
            )
        }
        let allAlbums = collections(mode: .artists).flatMap { albums(for: $0, mode: .artists) }
        results.albums = allAlbums.filter {
            $0.title.lowercased().contains(needle) || $0.artist.lowercased().contains(needle)
        }
        results.tracks = allAlbums.flatMap { tracks(albumID: $0.id) }.filter {
            $0.title.lowercased().contains(needle)
                || $0.artist.lowercased().contains(needle)
                || $0.album.lowercased().contains(needle)
        }
        return results
    }

    /// Enhanced LRC, so `hum demo` exercises the karaoke path — line timings
    /// plus `<mm:ss.cc>` word markers.
    func lyrics(for track: Track) -> String? {
        guard track.hasLyrics else { return nil }
        return """
        [ar:\(track.artist)]
        [ti:\(track.title)]
        [00:00.50]♪ \(track.title) — \(track.artist)
        [00:02.00] <00:02.00>These <00:02.60>are <00:03.20>demo <00:04.00>lyrics
        [00:06.00] <00:06.00>with <00:06.50>word <00:07.20>level <00:08.00>timings
        [00:10.00] <00:10.00>so <00:10.40>the <00:10.90>line <00:11.60>lights <00:12.40>up
        [00:14.00] <00:14.00>one <00:14.70>word <00:15.40>at <00:15.90>a <00:16.40>time
        [00:19.00]
        [00:21.00] This line has no word markers, so it highlights whole
        [00:26.00] and wraps if the pane is narrow enough to need it
        [00:31.00]
        [00:33.00] \(track.artist) — \(track.album)
        """
    }

    // MARK: - Fake playback
    //
    // A real queue rather than a single track, so the browser's transport keys
    // (next/previous/enqueue/volume) exercise the same code paths they would
    // against AVPlayer.




}

// MARK: - Cover art

extension DemoLibrary {
    /// A procedurally generated cover, so the now-playing pane has real artwork
    /// to render offline. Derived from the album id, so a given album always
    /// looks the same.
    func coverArt(for source: String) -> Data? {
        let size = 360
        let seed = source.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }

        // Hue walks the warm end of the wheel so covers stay in family with the
        // amber palette instead of fighting it.
        let hue = Double(seed % 360) / 360.0 * 0.18 + 0.05
        let accent = NSColor(calibratedHue: hue, saturation: 0.75, brightness: 0.92, alpha: 1)
        let deep = NSColor(calibratedHue: hue, saturation: 0.85, brightness: 0.30, alpha: 1)

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        NSColor(calibratedRed: 0.055, green: 0.067, blue: 0.086, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()

        // A corner wash, then the ")))" arcs from the icon at a size and offset
        // that vary per album.
        let gradient = NSGradient(starting: deep.withAlphaComponent(0.85), ending: .clear)
        gradient?.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: Double(seed % 90) + 200)

        let centreX = Double(size) * (0.18 + Double((seed >> 8) % 30) / 100.0)
        let centreY = Double(size) * (0.30 + Double((seed >> 16) % 40) / 100.0)
        for ring in 1...4 {
            let radius = Double(size) * 0.12 * Double(ring)
            let path = NSBezierPath()
            path.appendArc(
                withCenter: NSPoint(x: centreX, y: centreY),
                radius: radius,
                startAngle: -52,
                endAngle: 52
            )
            path.lineWidth = Double(size) * 0.022
            path.lineCapStyle = .round
            accent.withAlphaComponent(1.0 - Double(ring) * 0.2).setStroke()
            path.stroke()
        }

        let triangle = NSBezierPath()
        let tx = centreX - Double(size) * 0.13
        triangle.move(to: NSPoint(x: tx, y: centreY - Double(size) * 0.09))
        triangle.line(to: NSPoint(x: tx + Double(size) * 0.11, y: centreY))
        triangle.line(to: NSPoint(x: tx, y: centreY + Double(size) * 0.09))
        triangle.close()
        accent.setFill()
        triangle.fill()

        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
