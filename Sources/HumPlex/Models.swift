import Foundation

// MARK: - Wire format
//
// Plex's JSON wraps everything in a `MediaContainer`, with child objects in either
// `Directory` (browse nodes, library sections) or `Metadata` (items). Almost every
// field is optional in practice — different item types populate different subsets —
// so these structs stay permissive and the domain types below do the narrowing.

struct PlexEnvelope: Decodable {
    struct Container: Decodable {
        var size: Int?
        /// Items available in total, when the request was paginated.
        var totalSize: Int?
        var title1: String?
        var title2: String?
        var directories: [PlexDirectory]?
        var metadata: [PlexMetadata]?
        /// `/hubs/search` groups its results into hubs — one per result kind —
        /// instead of returning a flat `Metadata` list.
        var hubs: [PlexHub]?

        enum CodingKeys: String, CodingKey {
            case size, totalSize, title1, title2
            case directories = "Directory"
            case metadata = "Metadata"
            case hubs = "Hub"
        }

        /// Every item in the container, whether it arrived flat or inside hubs.
        ///
        /// Callers partition on each item's own `type` rather than on the hub it
        /// came from, which makes this work for both response shapes — and Plex
        /// is not consistent about which one an endpoint uses.
        var allMetadata: [PlexMetadata] {
            (metadata ?? []) + (hubs ?? []).flatMap { $0.metadata ?? [] }
        }
    }

    var container: Container

    enum CodingKeys: String, CodingKey {
        case container = "MediaContainer"
    }
}

struct PlexHub: Decodable {
    var title: String?
    /// "artist", "album", "track", "playlist", …
    var type: String?
    var hubIdentifier: String?
    var size: Int?
    var metadata: [PlexMetadata]?
    var directories: [PlexDirectory]?

    enum CodingKeys: String, CodingKey {
        case title, type, hubIdentifier, size
        case metadata = "Metadata"
        case directories = "Directory"
    }
}

struct PlexDirectory: Decodable {
    var key: String?
    var type: String?
    var title: String?
    var uuid: String?
    var agent: String?
}

struct PlexMetadata: Decodable {
    var ratingKey: String?
    var key: String?
    var guid: String?
    var type: String?
    var title: String?
    var titleSort: String?
    var originalTitle: String?
    var summary: String?
    var parentTitle: String?
    var parentRatingKey: String?
    var grandparentTitle: String?
    var grandparentRatingKey: String?
    var index: Int?
    var parentIndex: Int?
    var year: Int?
    /// The viewer's own rating, 0–10. Plex's UI shows it as five stars, so each
    /// star is two points and odd values are half stars.
    var userRating: Double?
    /// Tracks in a playlist or album.
    var leafCount: Int?
    /// The release year of the album this track belongs to.
    var parentYear: Int?
    var duration: Int?  // milliseconds
    var thumb: String?
    var parentThumb: String?
    var art: String?
    var addedAt: Int?
    var viewCount: Int?
    var media: [PlexMedia]?
    var genres: [PlexTag]?
    var labels: [PlexTag]?
    var moods: [PlexTag]?
    var styles: [PlexTag]?

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, guid, type, title, titleSort, originalTitle, summary
        case parentTitle, parentRatingKey, grandparentTitle, grandparentRatingKey
        case index, parentIndex, year, duration, thumb, parentThumb, art, addedAt, viewCount
        case userRating, leafCount, parentYear
        case media = "Media"
        case genres = "Genre"
        case labels = "Label"
        case moods = "Mood"
        case styles = "Style"
    }
}

struct PlexMedia: Decodable {
    var id: Int?
    var duration: Int?
    var bitrate: Int?
    var audioChannels: Int?
    var audioCodec: String?
    var container: String?
    var parts: [PlexPart]?

    enum CodingKeys: String, CodingKey {
        case id, duration, bitrate, audioChannels, audioCodec, container
        case parts = "Part"
    }
}

struct PlexPart: Decodable {
    var id: Int?
    var key: String?
    var duration: Int?
    var file: String?
    var size: Int?
    var container: String?
    var streams: [PlexStream]?

    enum CodingKeys: String, CodingKey {
        case id, key, duration, file, size, container
        case streams = "Stream"
    }
}

struct PlexStream: Decodable {
    var id: Int?
    /// 1 = video, 2 = audio, 3 = subtitle, 4 = lyrics.
    var streamType: Int?
    var codec: String?
    var format: String?
    var key: String?
    var displayTitle: String?
}

struct PlexTag: Decodable {
    var id: Int?
    var tag: String?
    var filter: String?
}

// MARK: - Domain types

public struct LibrarySection: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// Plex's section type: "artist" for music, "movie"/"show" for video. hum
    /// only browses music, so `musicSections(on:)` filters on `isMusic`.
    public let type: String

    public init(id: String, title: String, type: String) {
        self.id = id
        self.title = title
        self.type = type
    }

    public var isMusic: Bool { type == "artist" }
}

public struct Artist: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let albumCount: Int?
    public let thumb: String?
    public let genres: [String]

    public init(id: String, title: String, albumCount: Int?, thumb: String?, genres: [String]) {
        self.id = id
        self.title = title
        self.albumCount = albumCount
        self.thumb = thumb
        self.genres = genres
    }

    public var sortKey: String { title.lowercased() }
}

public struct Album: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let artistID: String?
    public let year: Int?
    public let thumb: String?
    public let genres: [String]
    public let labels: [String]

    public init(
        id: String,
        title: String,
        artist: String,
        artistID: String?,
        year: Int?,
        thumb: String?,
        genres: [String],
        labels: [String]
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artistID = artistID
        self.year = year
        self.thumb = thumb
        self.genres = genres
        self.labels = labels
    }
}

public struct Track: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let album: String
    public let albumID: String?
    public let artist: String
    public let trackNumber: Int?
    public let discNumber: Int?
    /// Seconds. Plex reports milliseconds; converted on the way in.
    public let duration: Double
    /// Server-relative media path, e.g. `/library/parts/1234/.../file.flac`.
    public let partKey: String?
    public let thumb: String?
    public let hasLyrics: Bool
    /// Every path worth trying for this track's lyrics, best first.
    ///
    /// A track can carry more than one lyrics stream — a sidecar file *and* an
    /// embedded tag, say — and only the sidecar gets a `key`. Keeping just the
    /// first stream found meant that a track with both could be represented by
    /// the one that cannot be fetched, and the other was never tried.
    public let lyricsCandidatePaths: [String]
    /// Whether the response this track was parsed from carried stream data at
    /// all. Distinguishes "the server told us about the streams and there are
    /// no lyrics" from "the server did not tell us about the streams" — without
    /// it, both look like `hasLyrics == false` and the only safe response is to
    /// ask again, which doubles the requests for every album browsed.
    public let hasStreamData: Bool
    /// The release year of the track's own album.
    ///
    /// On the track rather than looked up from whichever album is selected.
    /// The metadata pane used to append the year only when
    /// `selectedAlbum?.title == track.album`, which meant a playlist or the
    /// rated list — where no album is selected — showed none at all, and two
    /// albums sharing a title could put one's year on the other's track.
    public let albumYear: Int?

    /// The viewer's own rating, 0–10, or nil if never rated.
    ///
    /// Plex's own scale. Kept as it comes rather than converted to stars, so
    /// that a half star survives a round trip and `PUT /:/rate` can send back
    /// exactly what it was given.
    public let userRating: Double?
    public let codec: String?
    public let bitrate: Int?

    public init(
        id: String,
        title: String,
        album: String,
        albumID: String?,
        artist: String,
        trackNumber: Int?,
        discNumber: Int?,
        duration: Double,
        partKey: String?,
        thumb: String?,
        hasLyrics: Bool,
        lyricsCandidatePaths: [String] = [],
        hasStreamData: Bool = true,
        albumYear: Int? = nil,
        userRating: Double? = nil,
        codec: String?,
        bitrate: Int?
    ) {
        self.id = id
        self.title = title
        self.album = album
        self.albumID = albumID
        self.artist = artist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.partKey = partKey
        self.thumb = thumb
        self.hasLyrics = hasLyrics
        self.lyricsCandidatePaths = lyricsCandidatePaths
        self.hasStreamData = hasStreamData
        self.albumYear = albumYear
        self.userRating = userRating
        self.codec = codec
        self.bitrate = bitrate
    }

    /// A copy with a different rating. `Track` is a value type held in several
    /// places at once — the list on screen, a cache, the player — and they have
    /// to agree.
    public func withRating(_ rating: Double?) -> Track {
        Track(
            id: id, title: title, album: album, albumID: albumID, artist: artist,
            trackNumber: trackNumber, discNumber: discNumber, duration: duration,
            partKey: partKey, thumb: thumb, hasLyrics: hasLyrics,
            lyricsCandidatePaths: lyricsCandidatePaths, hasStreamData: hasStreamData,
            albumYear: albumYear, userRating: rating, codec: codec, bitrate: bitrate
        )
    }
}

// MARK: - Mapping

extension PlexDirectory {
    var asLibrarySection: LibrarySection? {
        guard let key, let title else { return nil }
        return LibrarySection(id: key, title: title, type: type ?? "unknown")
    }
}

/// Plex stores a rating as 0–10 and shows it as five stars.
public enum Rating {
    /// Plex's range.
    public static let range: ClosedRange<Double> = 0...10

    /// `★★★☆☆`, with `★★★⯪☆` for a half. Fixed width, so a column of them
    /// lines up.
    public static func stars(_ rating: Double?) -> String {
        guard let rating, rating > 0 else { return "     " }
        let halves = Int((min(max(rating, 0), 10) / 2 * 2).rounded())
        var out = ""
        for position in 1...5 {
            let filled = halves >= position * 2
            let half = !filled && halves == position * 2 - 1
            out += filled ? "★" : (half ? "⯪" : "☆")
        }
        return out
    }

    /// Whole stars, for keys 1–5. `0` clears.
    public static func fromStars(_ stars: Int) -> Double {
        Double(min(max(stars, 0), 5)) * 2
    }

    /// Whole stars a rating rounds to, for reporting what was set.
    public static func starCount(_ rating: Double?) -> Int {
        guard let rating else { return 0 }
        return Int((min(max(rating, 0), 10) / 2).rounded())
    }
}

/// A title that is present but blank is not a title.
///
/// `guard let title` only catches a *missing* one. An entry whose title was
/// present and empty sailed straight through and became a blank row in the
/// list — selectable, playable, and with nothing written on it. A real library
/// had one at the very top of its artist list (an empty `titleSort` sorts
/// before `*NSYNC`), which is exactly what hum selects at startup, so the
/// default view was a blank artist, a blank album and seventeen blank tracks.
/// It reads as a rendering fault rather than as data.
private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Shown in place of a blank title, so an unnamed item is visibly an unnamed
/// item rather than an empty row.
private let untitled = "(untitled)"

extension PlexMetadata {
    var tagNames: [String] { (genres ?? []).compactMap(\.tag) }

    var asArtist: Artist? {
        guard let ratingKey, title != nil else { return nil }
        return Artist(
            id: ratingKey,
            title: nonEmpty(title) ?? untitled,
            albumCount: nil,
            thumb: thumb,
            genres: tagNames
        )
    }

    var asAlbum: Album? {
        guard let ratingKey, title != nil else { return nil }
        return Album(
            id: ratingKey,
            title: nonEmpty(title) ?? untitled,
            artist: nonEmpty(parentTitle) ?? nonEmpty(originalTitle) ?? "Unknown Artist",
            artistID: parentRatingKey,
            year: year,
            thumb: thumb ?? parentThumb,
            genres: tagNames,
            labels: (labels ?? []).compactMap(\.tag)
        )
    }

    var asPlaylist: Playlist? {
        guard let ratingKey, title != nil else { return nil }
        return Playlist(
            id: ratingKey,
            title: nonEmpty(title) ?? untitled,
            count: leafCount,
            duration: duration.map { Double($0) / 1000.0 }
        )
    }

    var asTrack: Track? {
        guard let ratingKey, title != nil else { return nil }
        let part = media?.first?.parts?.first
        // Scan every media and every part: a track with more than one — a
        // transcode variant, a multi-file release — can carry its lyrics stream
        // somewhere other than the first, and looking only at the first missed it.
        // Every lyrics stream across every media and part, not just the first.
        // Sidecar streams carry a `key` and are the ones that actually fetch, so
        // they go first; id-derived paths follow as a fallback for embedded
        // lyrics. Trying only one candidate is how a track with both ended up
        // reporting none.
        let allStreams = (media ?? [])
            .flatMap { $0.parts ?? [] }
            .flatMap { $0.streams ?? [] }
        let lyricStreams = allStreams.filter { $0.streamType == 4 }

        var candidatePaths: [String] = []
        for stream in lyricStreams {
            guard let key = stream.key, !key.isEmpty else { continue }
            if !candidatePaths.contains(key) { candidatePaths.append(key) }
        }
        for stream in lyricStreams {
            guard let id = stream.id else { continue }
            let byID = "/library/streams/\(id)"
            if !candidatePaths.contains(byID) { candidatePaths.append(byID) }
        }

        let milliseconds = duration ?? media?.first?.duration ?? part?.duration ?? 0

        return Track(
            id: ratingKey,
            title: nonEmpty(title) ?? untitled,
            album: nonEmpty(parentTitle) ?? "Unknown Album",
            albumID: parentRatingKey,
            artist: nonEmpty(grandparentTitle) ?? nonEmpty(originalTitle) ?? "Unknown Artist",
            trackNumber: index,
            discNumber: parentIndex,
            duration: Double(milliseconds) / 1000.0,
            partKey: part?.key,
            thumb: thumb ?? parentThumb,
            hasLyrics: !lyricStreams.isEmpty,
            lyricsCandidatePaths: candidatePaths,
            hasStreamData: !allStreams.isEmpty,
            albumYear: parentYear,
            userRating: userRating,
            codec: media?.first?.audioCodec,
            bitrate: media?.first?.bitrate
        )
    }
}

/// A playlist, which for hum's purposes is a named flat list of tracks.
public struct Playlist: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// How many tracks, when the server says.
    public let count: Int?
    /// Total running time in seconds.
    public let duration: Double?

    public init(id: String, title: String, count: Int?, duration: Double?) {
        self.id = id
        self.title = title
        self.count = count
        self.duration = duration
    }
}

/// What a search turned up, split by kind.
public struct SearchResults: Sendable {
    public var artists: [Artist] = []
    public var albums: [Album] = []
    public var tracks: [Track] = []

    public init(artists: [Artist] = [], albums: [Album] = [], tracks: [Track] = []) {
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
    }

    public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && tracks.isEmpty }
    public var count: Int { artists.count + albums.count + tracks.count }
}

// MARK: - Resources (plex.tv account API)

/// A device on the account. We only care about the ones that `provides` "server".
struct PlexResource: Decodable {
    var name: String?
    var product: String?
    var productVersion: String?
    var platform: String?
    var clientIdentifier: String?
    var provides: String?
    var accessToken: String?
    var owned: Bool?
    var connections: [PlexConnection]?

    var providesServer: Bool {
        (provides ?? "").split(separator: ",").contains("server")
    }
}

struct PlexConnection: Decodable {
    var `protocol`: String?
    var address: String?
    var port: Int?
    var uri: String?
    var local: Bool?
    var relay: Bool?
}

/// A reachable Plex server: a base URL plus the token that works against it.
public struct PlexServer: Hashable, Sendable {
    public let name: String
    public let baseURL: URL
    public let accessToken: String
    public let isLocal: Bool
    public let isRelay: Bool
    public let clientIdentifier: String?

    public init(
        name: String,
        baseURL: URL,
        accessToken: String,
        isLocal: Bool,
        isRelay: Bool,
        clientIdentifier: String? = nil
    ) {
        self.name = name
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.isLocal = isLocal
        self.isRelay = isRelay
        self.clientIdentifier = clientIdentifier
    }

    /// Lower sorts first. Direct LAN beats direct WAN beats relay — relay is
    /// bandwidth-capped by plex.tv and feels nothing like "instant".
    var preferenceRank: Int {
        if isRelay { return 2 }
        return isLocal ? 0 : 1
    }
}
